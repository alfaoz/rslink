-- rslink.reliability — ACK, retry, dedup, and the RX symbol→frame pipeline.
--
-- Sender side (unicast):
--   * Assign monotonic SEQ.
--   * MAC-transmit the frame.
--   * Wait for an ACK matching (src=DST, dst=ME, seq=SEQ, payload empty).
--   * Timeout 500ms → retry up to N times with 100/200/400 ms backoff.
--
-- Sender side (broadcast):
--   * Fire-and-forget; no ACK.
--
-- Receiver side:
--   * poll_once() on symbol layer → 127-byte symbol with SYMBOL_SEQ header.
--   * Track expected SYMBOL_SEQ per session; on gap, discard the in-progress
--     frame buffer (resync on next START).
--   * Append symbol body to a byte stream and drain complete frames.
--   * For each frame: if dst is us or broadcast, dedup by (src, seq),
--     send ACK (unicast only), and either signal pending sends (LEN=0 =
--     ACK frame) or emit "rslink_message".

local config = require("rslink.config")
local frame  = require("rslink.frame")

local M = {}
M.__index = M

function M.new(mac, opts)
  opts = opts or {}
  local self = setmetatable({}, M)
  self.mac      = mac
  self.symbol   = mac.symbol
  self.my_id    = assert(opts.my_id, "reliability: my_id required")
  self.next_seq = 0
  self.recent   = {}    -- recent[src] = { [seq] = epoch_ms, ... }
  self.rx_buf   = {}
  self.last_sym_seq = nil
  self.ack_timeout_s = opts.ack_timeout_s or config.DEFAULT_ACK_TIMEOUT_S
  self.max_retries   = opts.max_retries   or config.DEFAULT_MAX_RETRIES
  self.backoff_ms    = opts.backoff_ms    or config.BACKOFF_MS
  self.dedup_ttl_ms  = opts.dedup_ttl_ms  or 5000
  -- Counters for the rslinkclient / rslinkview UIs.
  self.stats = {
    tx_frames = 0, tx_bytes = 0,
    rx_frames = 0, rx_bytes = 0,
    rx_bad_crc = 0, rx_dropped_dup = 0,
    rx_symbol_gaps = 0,
    ack_timeouts = 0,
  }
  return self
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local BROADCAST = config.BROADCAST_ID

local function next_seq(self)
  local s = self.next_seq
  self.next_seq = (self.next_seq + 1) % 256
  return s
end

local function remember_seq(self, src, seq)
  local now = os.epoch("utc")
  local entry = self.recent[src]
  if not entry then
    entry = {}
    self.recent[src] = entry
  end
  entry[seq] = now
  -- Prune stale
  local cutoff = now - self.dedup_ttl_ms
  for k, t in pairs(entry) do
    if t < cutoff then entry[k] = nil end
  end
end

local function is_recent(self, src, seq)
  local entry = self.recent[src]
  if not entry then return false end
  local t = entry[seq]
  if not t then return false end
  return (os.epoch("utc") - t) < self.dedup_ttl_ms
end

--------------------------------------------------------------------------------
-- Send
--------------------------------------------------------------------------------

-- Unicast: blocks waiting for ACK, retries on timeout. Returns true on ACK.
function M:send_unicast(dst, payload_str)
  local seq = next_seq(self)
  local bytes = frame.encode_frame(self.my_id, dst, seq, payload_str)

  for attempt = 0, self.max_retries do
    self.mac:transmit_bytes(bytes)
    self.stats.tx_frames = self.stats.tx_frames + 1
    self.stats.tx_bytes  = self.stats.tx_bytes + #bytes

    local timer = os.startTimer(self.ack_timeout_s)
    while true do
      local ev, a, b = os.pullEvent()
      if ev == "rslink_internal_ack" and a == dst and b == seq then
        os.cancelTimer(timer)
        return true
      elseif ev == "timer" and a == timer then
        self.stats.ack_timeouts = self.stats.ack_timeouts + 1
        break
      end
    end
    if attempt < self.max_retries then
      os.sleep(self.backoff_ms[attempt + 1] / 1000)
    end
  end
  return false
end

-- Broadcast: fire-and-forget.
function M:send_broadcast(payload_str)
  local seq = next_seq(self)
  local bytes = frame.encode_frame(self.my_id, BROADCAST, seq, payload_str)
  self.mac:transmit_bytes(bytes)
  self.stats.tx_frames = self.stats.tx_frames + 1
  self.stats.tx_bytes  = self.stats.tx_bytes + #bytes
end

-- Internal: send an ACK frame back to `dst` with `seq`. Empty payload.
function M:send_ack(dst, seq)
  local bytes = frame.encode_frame(self.my_id, dst, seq, "")
  self.mac:transmit_bytes(bytes)
  -- ACKs don't count toward tx_frames / tx_bytes user-visible counters by
  -- convention; track them separately if needed.
end

--------------------------------------------------------------------------------
-- Receive pipeline
--------------------------------------------------------------------------------

function M:handle_symbol(sym)
  -- SYMBOL_SEQ gap detection: if we expected next to be (last+1) mod 256 and
  -- it isn't, the in-progress frame is corrupt → drop the rx buffer.
  if self.last_sym_seq ~= nil then
    local expected = (self.last_sym_seq + 1) % 256
    if sym.symbol_seq ~= expected then
      if #self.rx_buf > 0 then
        self.stats.rx_symbol_gaps = self.stats.rx_symbol_gaps + 1
        self.rx_buf = {}
      end
    end
  end
  self.last_sym_seq = sym.symbol_seq

  -- Append symbol body bytes.
  local buf = self.rx_buf
  local base = #buf
  for i = 1, #sym.bytes do
    buf[base + i] = sym.bytes[i]
  end

  -- Drain complete frames.
  local frames, new_off = frame.drain_frames(buf, 1)
  if new_off > 1 then
    local trimmed = {}
    for i = new_off, #buf do
      trimmed[#trimmed + 1] = buf[i]
    end
    self.rx_buf = trimmed
  end

  for _, f in ipairs(frames) do
    self:handle_frame(f)
  end
end

function M:handle_frame(f)
  -- Drop our own echoes.
  if f.src == self.my_id then return end
  -- Drop frames not addressed to us.
  if f.dst ~= self.my_id and f.dst ~= BROADCAST then return end

  self.stats.rx_frames = self.stats.rx_frames + 1
  self.stats.rx_bytes  = self.stats.rx_bytes + #f.payload

  -- ACK frame? (LEN=0; user messages are always non-empty after serialize.)
  if #f.payload == 0 then
    if f.dst == self.my_id then
      os.queueEvent("rslink_internal_ack", f.src, f.seq)
    end
    return
  end

  -- Data frame. Unicast → ACK and dedup; broadcast → just deliver.
  if f.dst == self.my_id then
    if is_recent(self, f.src, f.seq) then
      self.stats.rx_dropped_dup = self.stats.rx_dropped_dup + 1
      -- Re-ACK in case our previous ACK was lost.
      self:send_ack(f.src, f.seq)
      return
    end
    remember_seq(self, f.src, f.seq)
    self:send_ack(f.src, f.seq)
    os.queueEvent("rslink_internal_frame", f.src, f.payload, false)
  else
    -- Broadcast.
    os.queueEvent("rslink_internal_frame", f.src, f.payload, true)
  end
end

-- Long-running receive coroutine. Pass to parallel.waitForAny alongside user
-- code that handles "rslink_message" events.
function M:run_rx()
  while true do
    local sym = self.symbol:poll_once()
    if sym then self:handle_symbol(sym) end
    os.sleep(0.05)
  end
end

return M
