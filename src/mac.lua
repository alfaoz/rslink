-- rslink.mac — carrier-sense multiple access for the shared redstone bus.
--
-- Before transmitting, sample the clock lane for K ticks. The bus is "clear"
-- iff the clock lane reads IDLE (0) for the entire window. Any other value
-- (1..14 = real seq, 15 = sentinel) means SOMEONE is mid-transmit or hasn't
-- finished clearing yet → back off a random number of ticks and retry.
--
-- This relies on the symbol layer's clear_lanes() writing the clock to IDLE
-- LAST, so a seen clock=IDLE means all 256 lanes have settled.
--
-- Collisions can still happen when two senders both pass carrier-sense in
-- the same tick. They are not detected by the MAC; the receiver catches them
-- via CRC failure, and the reliability layer retries on ACK timeout.

local config = require("rslink.config")
local IDLE   = config.CLOCK_IDLE

local M = {}
M.__index = M

function M.new(symbol_layer, opts)
  opts = opts or {}
  local self = setmetatable({}, M)
  self.symbol = symbol_layer
  self.bridge = symbol_layer.bridge
  self.alphabet = symbol_layer.alphabet
  self.carrier_sense_ticks = opts.carrier_sense_ticks or config.MAC_CARRIER_SENSE_TICKS
  self.backoff_min = opts.backoff_min or config.MAC_BACKOFF_MIN_TICKS
  self.backoff_max = opts.backoff_max or config.MAC_BACKOFF_MAX_TICKS
  -- TODO(v1.1): post-write read-back collision detect when this is true.
  self.collision_detect = opts.collision_detect or false
  return self
end

-- Sample the clock lane for K ticks; return true iff it reads IDLE the
-- entire time. Any non-IDLE value means another sender is mid-transmit
-- or hasn't finished clearing.
function M:carrier_sense()
  local cf = self.alphabet[1]
  for _ = 1, self.carrier_sense_ticks do
    if self.bridge.getLinkSignal(cf, cf) ~= IDLE then return false end
    os.sleep(0.05)
  end
  return true
end

function M:backoff()
  local ticks = math.random(self.backoff_min, self.backoff_max)
  os.sleep(ticks * 0.05)
end

-- Send a byte array. Blocks until the bus is idle, then transmits.
-- max_attempts: how many carrier-sense retries before giving up (default 10).
-- Returns true if transmitted, false if gave up.
function M:transmit_bytes(bytes, max_attempts)
  max_attempts = max_attempts or 10
  for _ = 1, max_attempts do
    if self:carrier_sense() then
      self.symbol:transmit_frame_bytes(bytes)
      return true
    end
    self:backoff()
  end
  return false
end

return M
