-- rslink.config — defaults, constants, frame-layer magic numbers.
--
-- Override per-program at rslink.open() time. The defaults here are validated
-- against the in-game tests in /tests/ (see SPEC.md).

local M = {}

-- 16-item alphabet → 256 ordered frequency pairs.
-- 1.19+ rare items, chosen to never collide with normal Create build wires.
-- DEPLOYMENT RULE: before turning rslink on, sweep your world for any
-- existing redstone-link pair that uses items from this list. A collision
-- corrupts the network AND drives someone else's machine.
M.ALPHABET = {
  "minecraft:nautilus_shell",         "minecraft:heart_of_the_sea",
  "minecraft:totem_of_undying",       "minecraft:dragon_breath",
  "minecraft:enchanted_golden_apple", "minecraft:end_crystal",
  "minecraft:conduit",                "minecraft:nether_star",
  "minecraft:elytra",                 "minecraft:trident",
  "minecraft:dragon_head",            "minecraft:echo_shard",
  "minecraft:music_disc_pigstep",     "minecraft:shulker_shell",
  "minecraft:wither_skeleton_skull",  "minecraft:beacon",
}

-- Lane layout
M.CLOCK_LANE       = 0
M.DATA_LANE_COUNT  = 255
-- Clock-lane value semantics (4 bits, 0..15):
--   0       = IDLE   (bus cleared; no active transmitter)
--   1..14   = real sequence number for the current symbol
--   15      = SENTINEL (transmitter is mid-write; do not latch)
-- Both IDLE and SENTINEL cause receivers to skip latching, so carrier-sense
-- can use IDLE as the unambiguous "safe to transmit" signal.
M.CLOCK_SENTINEL   = 15
M.CLOCK_IDLE       = 0
M.MIN_REAL_SEQ     = 1
M.MAX_REAL_SEQ     = 14

-- Frame
M.FRAME_START          = 0xA5
M.MAX_FRAME_PAYLOAD    = 256   -- on-wire cap; API fragments above this
M.HEADER_BYTES         = 6     -- START + SRC + DST + SEQ + LEN_LO + LEN_HI
M.TRAILER_BYTES        = 2     -- CRC16 little-endian

-- Symbol
M.SYMBOL_HEADER_BYTES  = 1     -- SYMBOL_SEQ
M.SYMBOL_BODY_BYTES    = 126   -- 254 nibbles / 2, minus SYMBOL_SEQ
M.SYMBOL_PERIOD_S      = 0.20  -- transmit cost: sentinel + parallel data + real_seq
M.INTER_SYMBOL_DELAY_S = 0.15  -- pause between back-to-back symbols so receivers
                               -- get a clean read window before next sentinel
                               -- (3 ticks: covers receiver's 2-tick parallel
                               -- read + 1 tick of jitter / scheduling margin)
M.SYMBOL_NIBBLES       = 254   -- 255 data lanes minus the SYMBOL_SEQ byte (2 nibbles)

-- IDs
M.BROADCAST_ID = 255
M.MIN_NODE_ID  = 1
M.MAX_NODE_ID  = 254

-- MAC
M.MAC_CARRIER_SENSE_TICKS = 3
M.MAC_BACKOFF_MIN_TICKS   = 5
M.MAC_BACKOFF_MAX_TICKS   = 30

-- Reliability
-- The receiver has to wait for our full transmit + 6-tick settle + ~6-tick
-- ordered clear before its carrier-sense can succeed, then transmit its own
-- ACK back with the same overhead. For a 1-symbol ping that's ~45 ticks
-- (2.3 s) on the happy path; 4 s leaves room for a backoff cycle or two.
M.DEFAULT_ACK_TIMEOUT_S = 4.0
M.DEFAULT_MAX_RETRIES   = 3
M.BACKOFF_MS            = { 200, 400, 800 }
M.DEDUP_WINDOW          = 16

return M
