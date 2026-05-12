-- test_self_propagation.lua
-- Answers: when I write a value to a bridge, can I read it back immediately,
-- or only after N ticks?
--
-- This is the cheap version of the propagation test - everything on one
-- computer. It tells us about a SINGLE bridge's read-after-write latency.
-- For cross-bridge latency (the real T), run test_cross_send + test_cross_recv.
--
-- Setup: 1 computer, 1 redstone_link_bridge peripheral.

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
  error("attach a redstone_link_bridge peripheral first", 0)
end

local F1 = "minecraft:nautilus_shell"
local F2 = "minecraft:heart_of_the_sea"

local function trial(target, sleep_ticks)
  bridge.sendLinkSignal(F1, F2, 0)
  os.sleep(0.15)  -- let it settle
  bridge.sendLinkSignal(F1, F2, target)
  if sleep_ticks > 0 then
    os.sleep(sleep_ticks * 0.05)
  end
  return bridge.getLinkSignal(F1, F2)
end

print("Self-read propagation: write a value, read it back after N ticks.")
print()
print("  delay (ticks) |  hits  |  notes")
print("  --------------+--------+---------")

local TRIALS = 12
for delay = 0, 4 do
  local hits = 0
  for _ = 1, TRIALS do
    if trial(7, delay) == 7 then hits = hits + 1 end
    os.sleep(0.1)
  end
  local note = ""
  if hits == TRIALS then note = "consistent" end
  if hits == 0       then note = "never visible at this delay" end
  print(("       %d      |  %2d/%-2d |  %s"):format(delay, hits, TRIALS, note))
end

bridge.sendLinkSignal(F1, F2, 0)
print()
print("Smallest delay with hits=TRIALS is the self-read latency for one bridge.")
print("Cross-bridge latency may be larger - run test_cross_send/recv to measure.")
