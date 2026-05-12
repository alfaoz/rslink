-- rslink.symbol — symbol-level TX and RX.
--
-- A symbol is 255 nibbles spread across 255 distinct frequency pairs, plus
-- a clock lane bumped last to publish the symbol to receivers. Nibble layout:
--
--   lane 1     SYMBOL_SEQ high nibble
--   lane 2     SYMBOL_SEQ low  nibble
--   lane 3..254  frame data, big-endian nibbles (252 nibbles = 126 bytes)
--   lane 255   reserved (always 0; future use)
--
-- Clock lane (lane 0):
--   value 0     — IDLE: bus cleared / no active transmitter (receivers skip)
--   value 1..14 — real seq number for this symbol (cycles 1..14, skips 0)
--   value 15    — SENTINEL: transmitter is mid-write, do not latch
--
-- Receivers only latch when the clock lane transitions to a real seq value
-- (1..14) distinct from their last latched value. IDLE and SENTINEL both
-- count as "interruption observed", so the receiver will re-latch on the
-- next real value even if it happens to repeat the last seq.

local config   = require("rslink.config")
local resolver = require("rslink.resolver")
local frame    = require("rslink.frame")

local M = {}
M.__index = M

local SENTINEL   = config.CLOCK_SENTINEL
local IDLE       = config.CLOCK_IDLE
local MAX_SEQ    = config.MAX_REAL_SEQ
local DATA_LANES = config.DATA_LANE_COUNT
local SYMBOL_NIBBLES = 254       -- 255 data lanes; last is reserved

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------

function M.new(opts)
  opts = opts or {}
  local self = setmetatable({}, M)
  self.bridge   = opts.bridge or peripheral.find("redstone_link_bridge")
  self.alphabet = opts.alphabet or config.ALPHABET
  if not self.bridge then
    error("rslink.symbol: no redstone_link_bridge peripheral found", 2)
  end
  self.tx_clock_seq    = 0     -- last published clock seq; bumped before each symbol
  self.tx_symbol_seq   = 0     -- our next SYMBOL_SEQ counter (0..255)
  self.last_real_clock = nil   -- last real-seq clock value latched (1..14)
  self.saw_sentinel    = false -- observed IDLE or SENTINEL since last latch?
  -- bridge_state[lane] mirrors the value currently held on our bridge for
  -- each (i,j) pair (lane 0 = clock, 1..255 = data). Used to diff-write:
  -- we only call sendLinkSignal for lanes whose target value differs from
  -- what we last set. Synced with the actual peripheral by force_clear().
  self.bridge_state = {}
  for lane = 0, 255 do self.bridge_state[lane] = 0 end
  -- Force the peripheral to match our zero-state assumption in case a
  -- previous Lua session crashed without calling close().
  self:force_clear()
  return self
end

--------------------------------------------------------------------------------
-- Transmit
--------------------------------------------------------------------------------

-- transmit_symbol(nibbles_254)  — nibbles[1..254], values 0..15
-- Lane 255 is implicitly 0. Caller has already prepended SYMBOL_SEQ as
-- nibbles[1..2].
--
-- Diff-write optimization: we maintain bridge_state[] mirroring what the
-- peripheral currently holds, and only call sendLinkSignal for lanes whose
-- desired value differs. For a small payload that touches ~30 of 255 lanes,
-- this collapses ~5 ticks of parallel writes down to ~1 tick.
function M:transmit_symbol(nibbles)
  local bridge = self.bridge
  local alpha  = self.alphabet
  local cf1    = alpha[1]   -- (1,1) is clock lane (lane 0)
  local cf2    = alpha[1]
  local state  = self.bridge_state

  -- 1. Sentinel: park clock at SENTINEL so any receiver polling now skips.
  bridge.sendLinkSignal(cf1, cf2, SENTINEL)
  state[0] = SENTINEL

  -- 2. Diff-write data lanes — only the ones that change.
  local fns = {}
  local n = 0
  for lane = 1, DATA_LANES do
    local v = nibbles[lane] or 0
    if v ~= state[lane] then
      local i = math.floor(lane / 16) + 1
      local j = (lane % 16) + 1
      local f1, f2 = alpha[i], alpha[j]
      n = n + 1
      fns[n] = function() bridge.sendLinkSignal(f1, f2, v) end
      state[lane] = v
    end
  end
  if n > 0 then parallel.waitForAll(table.unpack(fns)) end

  -- 3. Publish real seq number → receivers latch and read all data lanes.
  -- Cycle through 1..MAX_SEQ (skip 0, which is the IDLE marker).
  self.tx_clock_seq = (self.tx_clock_seq % MAX_SEQ) + 1
  bridge.sendLinkSignal(cf1, cf2, self.tx_clock_seq)
  state[0] = self.tx_clock_seq
end

-- transmit_frame_bytes(byte_array) — splits into 126-byte chunks, prepends
-- per-chunk SYMBOL_SEQ, and transmits each chunk as one symbol.
--
-- After each symbol's real_seq is published, we sleep INTER_SYMBOL_DELAY_S
-- before starting the next symbol's sentinel write. Without this, multi-symbol
-- frames lose ~50% of their symbols to torn reads on the receiver side.
--
-- After the LAST symbol of a frame, we zero all 256 lanes on our bridge.
-- Create's redstone-link bridges hold and continuously rebroadcast their
-- last-set value. Without the clear, our last-written values persist on
-- the wire, and max-aggregation against the *next* transmitter blocks
-- their values whenever ours are higher — most catastrophically on the
-- clock lane (a receiver can't write clock=1 if we still hold clock=3,
-- because max(3,1)=3 and no transition is visible). This is what makes
-- ACKs and any back-and-forth traffic fail.
function M:transmit_frame_bytes(bytes)
  local n = #bytes
  local body_size = config.SYMBOL_BODY_BYTES   -- 126
  local gap_s     = config.INTER_SYMBOL_DELAY_S
  local pos = 1

  while pos <= n do
    local chunk_end = math.min(pos + body_size - 1, n)
    local chunk_len = chunk_end - pos + 1

    local symbol_bytes = { self.tx_symbol_seq }
    for i = 0, chunk_len - 1 do
      symbol_bytes[2 + i] = bytes[pos + i]
    end
    for i = chunk_len + 1, body_size do
      symbol_bytes[1 + i] = 0
    end

    local nibbles = frame.bytes_to_nibbles(symbol_bytes)
    self:transmit_symbol(nibbles)

    self.tx_symbol_seq = (self.tx_symbol_seq + 1) % 256
    pos = pos + chunk_len

    if pos <= n then
      os.sleep(gap_s)
    end
  end

  -- Settle: hold the last symbol on the wire long enough that any receiver
  -- whose poll caught clock=N can finish its parallel read of the 255 data
  -- lanes BEFORE clear_lanes starts zeroing them. Tested receiver-side
  -- batch read is ~2 ticks; 0.20s (4 ticks) gives 2 ticks of margin.
  os.sleep(0.20)

  -- Release the bus: zero all 256 lanes so we stop holding values.
  self:clear_lanes()
end

-- clear_lanes — zero the lanes we are currently holding non-zero on, so we
-- stop dominating the wire. Diff-clear (using bridge_state) means a small
-- frame only writes back the few lanes it dirtied (~1 tick) instead of all
-- 255 (~5 ticks). Order matters: data lanes first (in parallel), clock
-- lane LAST. wire-clock dropping to IDLE is the canonical "we are done"
-- signal that other senders' carrier-sense waits for.
function M:clear_lanes()
  local bridge = self.bridge
  local alpha  = self.alphabet
  local cf1, cf2 = alpha[1], alpha[1]
  local state  = self.bridge_state

  -- Phase 1: zero data lanes that we are currently holding non-zero.
  local fns = {}
  local n = 0
  for lane = 1, 255 do
    if state[lane] ~= 0 then
      local i = math.floor(lane / 16) + 1
      local j = (lane % 16) + 1
      local f1, f2 = alpha[i], alpha[j]
      n = n + 1
      fns[n] = function() bridge.sendLinkSignal(f1, f2, 0) end
      state[lane] = 0
    end
  end
  if n > 0 then parallel.waitForAll(table.unpack(fns)) end

  -- Phase 2: clock lane to IDLE last → publishes "we are done" atomically.
  bridge.sendLinkSignal(cf1, cf2, IDLE)
  state[0] = IDLE

  -- Mark interruption so our own RX re-latches on the next real symbol.
  self.saw_sentinel = true
end

-- force_clear — unconditional zero of every lane on our bridge, ignoring
-- bridge_state. Used at construction time to sync the peripheral to our
-- assumed-zero state in case a prior crash left it dirty.
function M:force_clear()
  local bridge = self.bridge
  local alpha  = self.alphabet
  local fns = {}
  for lane = 0, 255 do
    local i = math.floor(lane / 16) + 1
    local j = (lane % 16) + 1
    local f1, f2 = alpha[i], alpha[j]
    fns[lane + 1] = function() bridge.sendLinkSignal(f1, f2, 0) end
    self.bridge_state[lane] = 0
  end
  parallel.waitForAll(table.unpack(fns))
end

--------------------------------------------------------------------------------
-- Receive
--------------------------------------------------------------------------------

-- poll_once() → nil | { symbol_seq = N, bytes = {...126 bytes...} }
-- Returns a fresh symbol whenever the clock lane transitions to a new
-- non-sentinel value. Reads all 255 data lanes in parallel for speed.
--
-- Race protection: the receiver's parallel read takes ~2 ticks. If the sender
-- starts a new symbol during the read, data lanes can change mid-batch.
-- We detect this by re-reading the clock after the parallel batch and
-- discarding the read if the clock moved.
function M:poll_once()
  local bridge = self.bridge
  local alpha  = self.alphabet
  local cf1    = alpha[1]
  local cf2    = alpha[1]

  local clock = bridge.getLinkSignal(cf1, cf2)
  if clock == SENTINEL or clock == IDLE then
    -- Mid-write OR bus cleared — either way, not a latchable symbol.
    -- Note it so we can trigger on the next real value even if it happens
    -- to equal our last latched value (covers seq wraps & sender switches).
    self.saw_sentinel = true
    return nil
  end
  -- Trigger on either: clock changed since last latch, OR we observed
  -- an interruption (idle/sentinel) in between.
  if clock == self.last_real_clock and not self.saw_sentinel then
    return nil   -- no new symbol
  end

  -- New symbol — speculatively read all 255 data lanes in parallel.
  local nibbles = {}
  local fns = {}
  for lane = 1, DATA_LANES do
    local i = math.floor(lane / 16) + 1
    local j = (lane % 16) + 1
    local f1, f2 = alpha[i], alpha[j]
    fns[lane] = function()
      nibbles[lane] = bridge.getLinkSignal(f1, f2)
    end
  end
  parallel.waitForAll(table.unpack(fns))

  -- Verify clock didn't move during the read. If it did, the data lanes
  -- may be a torn mix of two symbols → discard and retry next tick.
  local clock_after = bridge.getLinkSignal(cf1, cf2)
  if clock_after ~= clock then
    return nil
  end

  self.last_real_clock = clock
  self.saw_sentinel    = false

  -- Decode nibbles → 127 bytes; first byte is SYMBOL_SEQ.
  local bytes = frame.nibbles_to_bytes(nibbles, 127)
  local symbol_seq = bytes[1]
  local body = {}
  for i = 2, 127 do body[i - 1] = bytes[i] end

  return {
    symbol_seq = symbol_seq,
    bytes      = body,
    clock      = clock,
  }
end

-- run_rx(on_symbol)  — long-running poll loop. Pass to parallel.waitForAny.
-- on_symbol(sym) is called for each fresh symbol received.
function M:run_rx(on_symbol)
  while true do
    local sym = self:poll_once()
    if sym then on_symbol(sym) end
    os.sleep(0.05)   -- 1 tick
  end
end

return M
