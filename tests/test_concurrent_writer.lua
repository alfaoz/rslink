-- test_concurrent_writer.lua
-- One of two competing writers for the concurrent-write test.
--
-- Usage:
--   test_concurrent_writer <value>          (run twice with different values)
--
-- Conventional pairing:
--   Computer A: test_concurrent_writer 3
--   Computer B: test_concurrent_writer 7
--   Computer C: test_concurrent_reader
--
-- All three bridges share the same frequency pair. Reader interprets the
-- histogram to determine whether Create aggregates concurrent writes via
-- max, last-writer-wins, or something else.

local args = { ... }
local v = tonumber(args[1])
if not v or v < 1 or v > 15 or v ~= math.floor(v) then
  error("usage: test_concurrent_writer <1..15>", 0)
end

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
  error("attach a redstone_link_bridge peripheral first", 0)
end

local F1 = "minecraft:nautilus_shell"
local F2 = "minecraft:heart_of_the_sea"

print(("Writer: writing v=%d every tick. Ctrl+T to stop."):format(v))

while true do
  bridge.sendLinkSignal(F1, F2, v)
  os.sleep(0.05)
end
