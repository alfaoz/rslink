-- test_yield.lua
-- Answers: does sendLinkSignal yield the coroutine per call?
--
-- Why it matters: rslink's framing relies on writing 255 data lanes and THEN
-- bumping the clock lane last, atomically from the receiver's point of view.
-- If sendLinkSignal yields per call, that invariant collapses and we need the
-- clock=15 sentinel approach (which we ship regardless, but this test tells us
-- whether we *also* need to budget for slow symbol transmission).
--
-- Setup: 1 computer, 1 redstone_link_bridge peripheral.

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
  error("attach a redstone_link_bridge peripheral first", 0)
end

local F1 = "minecraft:nautilus_shell"
local F2 = "minecraft:heart_of_the_sea"

-- Warm-up: 16 calls to load any one-shot JIT / class-init cost.
for i = 1, 16 do bridge.sendLinkSignal(F1, F2, i % 16) end

-- Time 255 calls (one symbol's worth in the rslink spec).
local N = 255
print(("Timing %d sendLinkSignal calls..."):format(N))
local t0 = os.epoch("utc")
for i = 1, N do
  bridge.sendLinkSignal(F1, F2, i % 16)
end
local dt = os.epoch("utc") - t0

print(("  elapsed: %d ms   (%.3f ms/call, %.1f ticks total)"):format(dt, dt / N, dt / 50))
print()

if dt < 50 then
  print("VERDICT: synchronous, fits in <1 tick.")
  print("  Clock-last works. Sentinel still recommended for forward compat.")
elseif dt < 200 then
  print("VERDICT: fast (~1-4 ticks). Probably yields rarely or in batches.")
  print("  Sentinel approach recommended.")
elseif dt < 2000 then
  print("VERDICT: slow, yields likely scattered across the loop.")
  print("  SENTINEL MANDATORY. Symbol period must be widened.")
else
  print("VERDICT: yields per call (or worse).")
  print("  SENTINEL MANDATORY. Reconsider symbol granularity entirely.")
end

bridge.sendLinkSignal(F1, F2, 0)
