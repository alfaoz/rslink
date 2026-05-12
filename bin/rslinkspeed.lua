-- rslinkspeed — one-shot throughput benchmark between two rslink nodes.
--
-- Usage:
--   rslinkspeed <dst_id> [bytes_per_msg=1000] [num_msgs=20]
--
-- Sends `num_msgs` unicast messages of `bytes_per_msg` payload bytes to the
-- destination node and reports actual wire-rate throughput (B/s, KB/s, MB/s),
-- per-message latency, and a min/avg/max breakdown.
--
-- The destination must be running rslink (e.g. rslinkclient) so it ACKs
-- and absorbs the messages. The receiver does not need any special setup.
--
-- Examples:
--   rslinkspeed 2                  -- 20 × 1000B (~20 KB total)
--   rslinkspeed 2 4000             -- 20 × 4000B (~80 KB total)
--   rslinkspeed 2 250 50           -- 50 × 250B  (12.5 KB total, more samples)
--   rslinkspeed 2 100 100          -- 100 × 100B (small-payload regime)

package.path = "/usr/allay/lib/?.lua;/usr/allay/lib/?/init.lua;" .. package.path
local rslink = require("rslink")
local config = rslink.config()

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function fmt_bytes(n)
  if n >= 1024 * 1024 then return string.format("%.2f MB", n / 1024 / 1024) end
  if n >= 1024         then return string.format("%.2f KB", n / 1024) end
  return string.format("%d B", math.floor(n))
end

local function fmt_rate(bps)
  if bps >= 1024 * 1024 then return string.format("%.2f MB/s", bps / 1024 / 1024) end
  if bps >= 1024        then return string.format("%.2f KB/s", bps / 1024) end
  return string.format("%.1f B/s", bps)
end

local function fmt_ms(ms)
  if ms >= 1000 then return string.format("%.2f s", ms / 1000) end
  return string.format("%d ms", math.floor(ms))
end

--------------------------------------------------------------------------------
-- Args
--------------------------------------------------------------------------------

local args = { ... }
local dst  = tonumber(args[1])
local size = tonumber(args[2]) or 1000
local n    = tonumber(args[3]) or 20

if not dst then
  print("usage: rslinkspeed <dst_id> [bytes_per_msg=1000] [num_msgs=20]")
  return
end
if dst < config.MIN_NODE_ID or dst > config.MAX_NODE_ID then
  print(("dst must be %d..%d"):format(config.MIN_NODE_ID, config.MAX_NODE_ID))
  return
end
if size < 1 or size > 60000 then
  print("bytes_per_msg must be 1..60000")
  return
end
if n < 1 or n > 1000 then
  print("num_msgs must be 1..1000")
  return
end

--------------------------------------------------------------------------------
-- Self id (cached in .rslink_id so reruns don't re-prompt)
--------------------------------------------------------------------------------

local id_cache = ".rslink_id"
local my_id
if fs.exists(id_cache) then
  local f = fs.open(id_cache, "r")
  my_id = tonumber(f.readAll())
  f.close()
end
if not my_id then
  write("enter this node's id (1..254): ")
  my_id = tonumber(read())
  if my_id then
    local f = fs.open(id_cache, "w")
    f.write(tostring(my_id))
    f.close()
  end
end
if not my_id or my_id == dst then
  print("invalid id (or same as dst)")
  return
end

rslink.open(my_id)

--------------------------------------------------------------------------------
-- The test
--------------------------------------------------------------------------------

local function run_test()
  -- Use a varied payload so any nibble-level optimization is honest.
  -- (all-X gives an unfair advantage to diff-write since most nibbles repeat)
  local payload = {}
  for i = 1, size do
    payload[i] = string.char((i * 31 + 7) % 256)
  end
  payload = table.concat(payload)

  print(("rslinkspeed: %d → %d"):format(my_id, dst))
  print(("  payload: %s × %d msgs = %s total")
    :format(fmt_bytes(size), n, fmt_bytes(size * n)))
  print()

  local times    = {}
  local ok_count = 0
  local fail_count = 0
  local t0 = os.epoch("utc")

  for i = 1, n do
    local mt0 = os.epoch("utc")
    local ok  = rslink.send(dst, payload)
    local mdt = os.epoch("utc") - mt0
    if ok then
      ok_count = ok_count + 1
      times[#times + 1] = mdt
      print(("  #%3d ok    %s"):format(i, fmt_ms(mdt)))
    else
      fail_count = fail_count + 1
      print(("  #%3d FAIL  %s"):format(i, fmt_ms(mdt)))
    end
  end

  local dt = (os.epoch("utc") - t0) / 1000
  local bytes_ok = ok_count * size

  print()
  print("results:")
  print(("  sent:        %s in %.2f s"):format(fmt_bytes(bytes_ok), dt))
  if bytes_ok > 0 then
    print(("  throughput:  %s"):format(fmt_rate(bytes_ok / dt)))
  end

  if #times > 0 then
    local sum, mn, mx = 0, math.huge, 0
    for _, t in ipairs(times) do
      sum = sum + t
      if t < mn then mn = t end
      if t > mx then mx = t end
    end
    local avg = sum / #times
    print(("  per-msg:     min %s / avg %s / max %s")
      :format(fmt_ms(mn), fmt_ms(avg), fmt_ms(mx)))
  end

  if fail_count > 0 then
    print(("  FAILED:      %d / %d messages"):format(fail_count, n))
  end
end

parallel.waitForAny(rslink.run, function()
  local ok, err = pcall(run_test)
  if not ok then printError(err) end
end)

rslink.close()
