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
--   value 0..14 — real seq number (cycles 0..14, wrap)
--   value 15    — SENTINEL: "data is mid-write, do not latch"
--
-- The receiver only latches when the clock lane transitions to a non-sentinel
-- value distinct from its last latched value. This makes the protocol robust
-- against partial writes even if sendLinkSignal yields the coroutine per call.

local config   = require("rslink.config")
local resolver = require("rslink.resolver")
local frame    = require("rslink.frame")

local M = {}
M.__index = M

local SENTINEL  = config.CLOCK_SENTINEL
local MAX_SEQ   = config.MAX_REAL_SEQ
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
  self.tx_clock_seq    = 0     -- our next clock sequence number to publish
  self.tx_symbol_seq   = 0     -- our next SYMBOL_SEQ counter (0..255)
  self.last_real_clock = nil   -- last non-sentinel clock value latched
  self.saw_sentinel    = false -- did we observe sentinel since last latch?
  return self
end

--------------------------------------------------------------------------------
-- Transmit
--------------------------------------------------------------------------------

-- transmit_symbol(nibbles_254)  — nibbles[1..254], values 0..15
-- Lane 255 is implicitly 0. Caller has already prepended SYMBOL_SEQ as
-- nibbles[1..2].
function M:transmit_symbol(nibbles)
  local bridge = self.bridge
  local alpha  = self.alphabet
  local cf1    = alpha[1]   -- (1,1) is clock lane (lane 0)
  local cf2    = alpha[1]

  -- 1. Sentinel: park clock at 15 so any receiver polling now ignores us.
  bridge.sendLinkSignal(cf1, cf2, SENTINEL)

  -- 2. Parallel-dispatch all 255 data lanes. Each call yields ~1 tick;
  --    parallel.waitForAll lets them overlap in 2 ticks total for N=255.
  local fns = {}
  for lane = 1, DATA_LANES do
    local v = nibbles[lane] or 0
    local i = math.floor(lane / 16) + 1
    local j = (lane % 16) + 1
    local f1, f2 = alpha[i], alpha[j]
    fns[lane] = function()
      bridge.sendLinkSignal(f1, f2, v)
    end
  end
  parallel.waitForAll(table.unpack(fns))

  -- 3. Publish real seq number → receivers latch and read all data lanes.
  self.tx_clock_seq = (self.tx_clock_seq + 1) % (MAX_SEQ + 1)
  bridge.sendLinkSignal(cf1, cf2, self.tx_clock_seq)
end

-- transmit_frame_bytes(byte_array) — splits into 126-byte chunks, prepends
-- per-chunk SYMBOL_SEQ, and transmits each chunk as one symbol.
--
-- After each symbol's real_seq is published, we sleep INTER_SYMBOL_DELAY_S
-- before starting the next symbol's sentinel write. This gives any polling
-- receiver enough time to (a) detect our clock change, (b) finish its
-- parallel-read of all 255 data lanes (~2 ticks), and (c) re-check the
-- clock to confirm no one else moved it — all before we'd start the next
-- symbol's data writes. Without this, multi-symbol frames lose ~50% of
-- their symbols to torn reads on the receiver side.
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
  if clock == SENTINEL then
    -- Note the sentinel so we can trigger on the next real value even if
    -- it happens to equal our last latched value (two senders cycling).
    self.saw_sentinel = true
    return nil
  end
  -- Trigger on either: clock changed since last latch, OR we observed
  -- the sentinel in between (covers same-value-from-different-sender).
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
