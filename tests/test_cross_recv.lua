-- test_cross_recv.lua
-- Half 2 of 2 for the cross-bridge propagation test.
--
-- Setup: 2 computers, 2 redstone_link_bridges, same world.
--   Computer A (other script): test_cross_send
--   Computer B (this script): test_cross_recv
-- Start this RECEIVER first, then the sender. Receiver polls every tick.
--
-- The first transition's (recv_t - send_t) is the cross-bridge propagation
-- latency T in milliseconds. T/50 gives ticks. T=0 means same-tick visibility.

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
  error("attach a redstone_link_bridge peripheral first", 0)
end

local F1 = "minecraft:nautilus_shell"
local F2 = "minecraft:heart_of_the_sea"

print("Polling every tick. Will record up to 40 transitions.")
print("(Ctrl+T to stop early.)")
print()

local last = bridge.getLinkSignal(F1, F2)
local n = 0
while n < 40 do
  os.sleep(0.05)
  local v = bridge.getLinkSignal(F1, F2)
  if v ~= last then
    n = n + 1
    print(("[%2d] saw v=%2d at t=%d   (was %d)"):format(n, v, os.epoch("utc"), last))
    last = v
  end
end

print()
print("Done. Match these [i] lines to the sender's [i] lines.")
print("(recv_t - send_t) per pair = propagation latency, ms.")
