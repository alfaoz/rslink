-- test_cross_send.lua
-- Half 1 of 2 for the cross-bridge propagation test.
--
-- Setup: 2 computers, 2 redstone_link_bridges, same world.
--   Computer A (this script): test_cross_send
--   Computer B (other script): test_cross_recv
-- Start the RECEIVER first, then this sender.
--
-- Output: 30 lines of "[i] wrote v=N at t=EPOCH_MS".
-- Compare with the receiver's "[i] saw v=N at t=EPOCH_MS" lines: the per-line
-- delta in milliseconds, divided by 50, is the propagation latency in ticks.

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
  error("attach a redstone_link_bridge peripheral first", 0)
end

local F1 = "minecraft:nautilus_shell"
local F2 = "minecraft:heart_of_the_sea"

print("Resetting line...")
bridge.sendLinkSignal(F1, F2, 0)
os.sleep(2)

print("Starting in 3s - make sure the receiver is already running.")
os.sleep(3)

local N = 30
for i = 1, N do
  local v = (i % 14) + 1  -- 1..14, never 0, never 15 (reserved sentinel)
  local t = os.epoch("utc")
  bridge.sendLinkSignal(F1, F2, v)
  print(("[%2d] wrote v=%2d at t=%d"):format(i, v, t))
  os.sleep(0.25)  -- 5 ticks between writes; receiver always catches up
end

bridge.sendLinkSignal(F1, F2, 0)
print()
print("Done. Compare timestamps with the receiver's output.")
print("Per transition: (recv_t - send_t) / 50 = propagation in ticks.")
