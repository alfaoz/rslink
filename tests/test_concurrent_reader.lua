-- test_concurrent_reader.lua
-- Reader for the concurrent-write test. Start AFTER both writers are running.
--
-- Setup: 3 computers, 3 redstone_link_bridges, same freq pair.
--   Computer A: test_concurrent_writer 3
--   Computer B: test_concurrent_writer 7
--   Computer C (this): test_concurrent_reader
--
-- Interpretation:
--   only 7  ........... MAX aggregation (Create's documented behavior, good)
--   only 3  ........... MIN aggregation (would surprise; spec needs review)
--   mix of 3 and 7  ... last-writer-wins (race window each tick; MAC layer
--                       must rely on CRC/retry, can't trust read-back)
--   value 10 .......... SUM (spec needs total redesign)
--   any other ......... unknown; investigate before writing code

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
  error("attach a redstone_link_bridge peripheral first", 0)
end

local F1 = "minecraft:nautilus_shell"
local F2 = "minecraft:heart_of_the_sea"

local SAMPLES = 300
local hist = {}
for i = 0, 15 do hist[i] = 0 end

print(("Sampling %d times (1 per tick, ~15s)..."):format(SAMPLES))
for _ = 1, SAMPLES do
  local v = bridge.getLinkSignal(F1, F2)
  hist[v] = hist[v] + 1
  os.sleep(0.05)
end

print()
print("--- Histogram ---")
for v = 0, 15 do
  if hist[v] > 0 then
    print(("  %2d: %3d  (%5.1f%%)"):format(v, hist[v], hist[v] * 100 / SAMPLES))
  end
end

print()
local seen = {}
for v = 0, 15 do
  if hist[v] > 0 then seen[#seen + 1] = v end
end

if #seen == 1 then
  print(("Single value seen: %d"):format(seen[1]))
  if seen[1] == 7 then
    print("=> MAX aggregation. Spec's read-back collision-detect plan works.")
  elseif seen[1] == 3 then
    print("=> MIN aggregation. Spec needs review.")
  else
    print("=> Unexpected single value. Investigate.")
  end
elseif #seen == 2 and hist[3] > 0 and hist[7] > 0 then
  print("=> Mixed 3 and 7. Looks like last-writer-wins or interleaved.")
  print("   Read-back collision detection is unreliable; rely on CRC + retry.")
else
  print("=> Unexpected distribution. Investigate aggregation semantics.")
end
