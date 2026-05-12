-- rslink — rednet-shaped wireless networking on Create's redstone link bus.
--
-- API surface mirrors rednet so most existing programs port with a sed:
--
--   local rslink = require("rslink")
--
--   rslink.open(42)
--
--   parallel.waitForAny(
--     function()
--       while true do
--         local _, from, msg, bcast = os.pullEvent("rslink_message")
--         print(from, msg)
--       end
--     end,
--     rslink.run
--   )
--
-- Or, with the convenience wrapper:
--
--   rslink.host(42, function()
--     while true do
--       local _, from, msg = os.pullEvent("rslink_message")
--       rslink.send(from, "got: " .. tostring(msg))
--     end
--   end)
--
-- Messages can be any value serializable via textutils.serialize. Large
-- messages are fragmented over multiple frames transparently (4-byte
-- per-frame header; max user message ~63 KB).

local config      = require("rslink.config")
local symbol_lib  = require("rslink.symbol")
local mac_lib     = require("rslink.mac")
local reli_lib    = require("rslink.reliability")

local M = {}

local FRAG_HEADER_BYTES = 4
local MAX_CHUNK_BYTES   = config.MAX_FRAME_PAYLOAD - FRAG_HEADER_BYTES  -- 252
local MAX_FRAGMENTS     = 255
local BROADCAST         = config.BROADCAST_ID

local state = {
  opened       = false,
  my_id        = nil,
  symbol       = nil,
  mac          = nil,
  reliability  = nil,
  next_msg_id  = 0,
  reassembly   = {},   -- [src][msg_id] = { total, received, chunks = {[idx]=str}, started_at }
  reassembly_ttl_ms = 10000,
}

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function M.is_open()
  return state.opened
end

function M.id()
  return state.my_id
end

function M.open(my_id, opts)
  if state.opened then error("rslink.open: already open", 2) end
  if type(my_id) ~= "number" or my_id < config.MIN_NODE_ID or my_id > config.MAX_NODE_ID then
    error(("rslink.open: id must be %d..%d"):format(config.MIN_NODE_ID, config.MAX_NODE_ID), 2)
  end
  opts = opts or {}
  state.symbol      = symbol_lib.new(opts)
  state.mac         = mac_lib.new(state.symbol, opts)
  state.reliability = reli_lib.new(state.mac, {
    my_id          = my_id,
    ack_timeout_s  = opts.ack_timeout_s,
    max_retries    = opts.max_retries,
    backoff_ms     = opts.backoff_ms,
  })
  state.my_id  = my_id
  state.opened = true
end

function M.close()
  -- Quiet the bridge before tearing down. Bridges continuously broadcast
  -- their last-set value onto Create's link network, even when the host
  -- computer is shut down — so leaving non-zero values on the lanes turns
  -- the bridge into a persistent transmitter that keeps occupying the bus.
  if state.symbol then
    local bridge   = state.symbol.bridge
    local alphabet = state.symbol.alphabet
    local fns = {}
    for lane = 0, 255 do
      local i = math.floor(lane / 16) + 1
      local j = (lane % 16) + 1
      local f1, f2 = alphabet[i], alphabet[j]
      fns[lane + 1] = function() bridge.sendLinkSignal(f1, f2, 0) end
    end
    pcall(parallel.waitForAll, table.unpack(fns))
  end
  state.opened      = false
  state.my_id       = nil
  state.symbol      = nil
  state.mac         = nil
  state.reliability = nil
  state.reassembly  = {}
end

local function assert_open()
  if not state.opened then error("rslink not open — call rslink.open(id) first", 3) end
end

--------------------------------------------------------------------------------
-- Send (with fragmentation)
--------------------------------------------------------------------------------

local function alloc_msg_id()
  local mid = state.next_msg_id
  state.next_msg_id = (state.next_msg_id + 1) % 65536
  return mid
end

local function build_fragment(mid, total, idx, chunk)
  return string.char(
    mid % 256,
    math.floor(mid / 256) % 256,
    total,
    idx
  ) .. chunk
end

local function split_into_chunks(payload_str)
  local total_len = #payload_str
  if total_len == 0 then
    return { "" }   -- still produce one chunk so the wire has something to send
  end
  local n = math.ceil(total_len / MAX_CHUNK_BYTES)
  if n > MAX_FRAGMENTS then
    error(("message too large: %d bytes (max %d)"):format(
      total_len, MAX_FRAGMENTS * MAX_CHUNK_BYTES), 3)
  end
  local out = {}
  for i = 1, n do
    local s = (i - 1) * MAX_CHUNK_BYTES + 1
    local e = math.min(s + MAX_CHUNK_BYTES - 1, total_len)
    out[i] = string.sub(payload_str, s, e)
  end
  return out
end

-- Unicast. Returns true iff every fragment was ACKed.
function M.send(dst, message)
  assert_open()
  if dst == BROADCAST then
    error("rslink.send: use rslink.broadcast for broadcasts", 2)
  end
  local payload = textutils.serialize(message)
  local chunks  = split_into_chunks(payload)
  local mid     = alloc_msg_id()
  local total   = #chunks
  for i, c in ipairs(chunks) do
    local frag = build_fragment(mid, total, i - 1, c)
    local ok = state.reliability:send_unicast(dst, frag)
    if not ok then return false end
  end
  return true
end

-- Broadcast: fire-and-forget. Returns immediately after queuing all fragments.
function M.broadcast(message)
  assert_open()
  local payload = textutils.serialize(message)
  local chunks  = split_into_chunks(payload)
  local mid     = alloc_msg_id()
  local total   = #chunks
  for i, c in ipairs(chunks) do
    local frag = build_fragment(mid, total, i - 1, c)
    state.reliability:send_broadcast(frag)
  end
end

--------------------------------------------------------------------------------
-- Receive pipeline (fragment reassembly → rslink_message events)
--------------------------------------------------------------------------------

local function get_reassembly(src, mid)
  local s = state.reassembly[src]
  if not s then s = {}; state.reassembly[src] = s end
  return s[mid]
end

local function put_reassembly(src, mid, r)
  state.reassembly[src][mid] = r
end

local function drop_reassembly(src, mid)
  local s = state.reassembly[src]
  if s then s[mid] = nil end
end

local function prune_reassembly_now()
  local cutoff = os.epoch("utc") - state.reassembly_ttl_ms
  for src, by_mid in pairs(state.reassembly) do
    for mid, r in pairs(by_mid) do
      if r.started_at < cutoff then
        by_mid[mid] = nil
      end
    end
  end
end

local function handle_internal_frame(src, payload_bytes_str, is_broadcast)
  if #payload_bytes_str < FRAG_HEADER_BYTES then
    return   -- malformed; drop
  end
  local b1, b2, total, idx = string.byte(payload_bytes_str, 1, 4)
  local mid = b1 + b2 * 256
  local chunk = string.sub(payload_bytes_str, FRAG_HEADER_BYTES + 1)

  if total == 1 then
    -- Fast path: no reassembly.
    local ok, msg = pcall(textutils.unserialize, chunk)
    if ok then
      os.queueEvent("rslink_message", src, msg, is_broadcast)
    end
    return
  end

  if idx >= total then return end   -- malformed

  local r = get_reassembly(src, mid)
  if not r then
    r = {
      total      = total,
      received   = 0,
      chunks     = {},
      started_at = os.epoch("utc"),
    }
    put_reassembly(src, mid, r)
  end

  if not r.chunks[idx] then
    r.chunks[idx] = chunk
    r.received = r.received + 1
  end

  if r.received == total then
    local parts = {}
    for i = 0, total - 1 do parts[i + 1] = r.chunks[i] end
    local full = table.concat(parts)
    drop_reassembly(src, mid)
    local ok, msg = pcall(textutils.unserialize, full)
    if ok then
      os.queueEvent("rslink_message", src, msg, is_broadcast)
    end
  end

  prune_reassembly_now()
end

--------------------------------------------------------------------------------
-- Run loops
--------------------------------------------------------------------------------

-- The receive coroutine. Pass to parallel.waitForAny alongside user code.
function M.run()
  assert_open()
  local function rx()       state.reliability:run_rx() end
  local function reassemble()
    while true do
      local ev, src, payload, bcast = os.pullEvent("rslink_internal_frame")
      handle_internal_frame(src, payload, bcast)
    end
  end
  parallel.waitForAny(rx, reassemble)
end

-- Convenience wrapper. Spawns M.run() alongside `user_main`.
function M.host(my_id, user_main, opts)
  if not state.opened then M.open(my_id, opts) end
  parallel.waitForAny(M.run, user_main)
end

--------------------------------------------------------------------------------
-- Blocking receive (mirrors rednet.receive)
--------------------------------------------------------------------------------

-- Blocks until an "rslink_message" event arrives or timeout.
-- Returns: from_id, message, is_broadcast  (or nil on timeout)
--
-- Note: rslink.receive() must be called from inside a coroutine that is
-- running alongside rslink.run() (use rslink.host or parallel.waitForAny).
function M.receive(timeout_s)
  local timer = timeout_s and os.startTimer(timeout_s)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "rslink_message" then
      if timer then os.cancelTimer(timer) end
      return a, b, c
    elseif timer and ev == "timer" and a == timer then
      return nil
    end
  end
end

--------------------------------------------------------------------------------
-- Stats (for rslinkclient / rslinkview)
--------------------------------------------------------------------------------

function M.stats()
  if not state.reliability then return nil end
  return state.reliability.stats
end

function M.config()
  return config
end

return M
