-- test_parallel_yield.lua
-- Decides whether parallel.waitForAll amortizes per-call sendLinkSignal yields.
--
-- Sequential 255-call yield test showed exactly 1 tick per call → 12.75 s per
-- symbol. If parallel dispatches let the calls yield concurrently within one
-- tick, throughput is recoverable. If not, the per-sender ceiling is ~80 bps
-- and the symbol design needs to shrink drastically.
--
-- Setup: 1 computer, 1 redstone_link_bridge.

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
  error("attach a redstone_link_bridge peripheral first", 0)
end

-- 16 rare items, 1.19+ (swap any that don't exist in your version).
local ALPHABET = {
  "minecraft:nautilus_shell",         "minecraft:heart_of_the_sea",
  "minecraft:totem_of_undying",       "minecraft:dragon_breath",
  "minecraft:enchanted_golden_apple", "minecraft:end_crystal",
  "minecraft:conduit",                "minecraft:nether_star",
  "minecraft:elytra",                 "minecraft:trident",
  "minecraft:dragon_head",            "minecraft:echo_shard",
  "minecraft:music_disc_pigstep",     "minecraft:shulker_shell",
  "minecraft:wither_skeleton_skull",  "minecraft:beacon",
}

local function pair_for_lane(lane)  -- lane ∈ [0, 255]
  local i = math.floor(lane / 16) + 1
  local j = (lane % 16) + 1
  return ALPHABET[i], ALPHABET[j]
end

-- Warm-up: touch 16 distinct lanes sequentially.
for lane = 0, 15 do
  local f1, f2 = pair_for_lane(lane)
  bridge.sendLinkSignal(f1, f2, lane)
end

local function time_parallel(n)
  local fns = {}
  for i = 1, n do
    local lane = i - 1
    fns[i] = function()
      local f1, f2 = pair_for_lane(lane)
      bridge.sendLinkSignal(f1, f2, i % 16)
    end
  end
  local t0 = os.epoch("utc")
  parallel.waitForAll(table.unpack(fns))
  return os.epoch("utc") - t0
end

print("parallel.waitForAll dispatching N concurrent sendLinkSignal calls")
print("across N distinct frequency pairs:")
print()
print("    N |  elapsed |  ms/call |  ticks")
print("  ----+----------+----------+--------")

local results = {}
for _, n in ipairs({ 1, 16, 64, 255 }) do
  local dt = time_parallel(n)
  results[n] = dt
  print(("  %3d | %5d ms |   %5.1f  |  %5.1f"):format(n, dt, dt / n, dt / 50))
  os.sleep(0.3)
end

print()
local dt255 = results[255]
if dt255 < 200 then
  print(("VERDICT (255 in %d ms): parallel AMORTIZES."):format(dt255))
  print("  Spec stands. Replace sequential loops with parallel dispatch.")
  print("  Throughput ~1 KB/s recovers.")
elseif dt255 < 2000 then
  print(("VERDICT (255 in %d ms): partial amortization."):format(dt255))
  print("  Worth picking an optimal fan-out width;")
  print("  throughput sits between worst and best case.")
else
  print(("VERDICT (255 in %d ms): parallel does NOT amortize."):format(dt255))
  print("  ~80 bps ceiling is real.")
  print("  Spec needs a redesign for skinnier symbols (1-2 data lanes max).")
end
