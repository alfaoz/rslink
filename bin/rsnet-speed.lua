-- rsnet-speed — true bandwidth speedtest for CC: Tweaked rednet.
--
-- Two roles. Run one on each computer:
--
--   rsnet-speed server                 -- print this node's ID, listen, echo
--   rsnet-speed test <id> [size] [n]   -- send n payloads of `size` bytes
--                                         to server, time the round trip
--
--   rsnet-speed sweep <id>             -- run a series of sizes
--                                         (64, 256, 1k, 4k, 16k, 64k bytes)
--                                         to find where throughput plateaus.
--
-- Throughput accounts for BOTH directions (request + echoed reply), so a
-- 1 KB request that comes back as 1 KB counts as 2 KB transferred.
--
-- Install:
--   wget https://raw.githubusercontent.com/alfaoz/rslink/main/bin/rsnet-speed.lua rsnet-speed

local function find_modem()
  for _, side in ipairs(rs.getSides()) do
    if peripheral.getType(side) == "modem" then
      return side, peripheral.wrap(side)
    end
  end
  return nil
end

local side, modem = find_modem()
if not side then
  print("error: no modem peripheral attached.")
  print("  attach a wired or ender modem and try again.")
  return
end
rednet.open(side)
local my_id = os.getComputerID()
local kind = modem.isWireless and (modem.isWireless() and "wireless" or "wired") or "unknown"

local args = { ... }
local mode = args[1]

local function fmt_bytes(n)
  if n >= 1024 * 1024 then return ("%.2f MB"):format(n / 1024 / 1024)
  elseif n >= 1024     then return ("%.2f KB"):format(n / 1024)
  else                      return ("%d B"):format(n) end
end

local function fmt_rate(bps)
  return fmt_bytes(bps) .. "/s"
end

--------------------------------------------------------------------------------
-- Server: echo every received message back to its sender.
--------------------------------------------------------------------------------

local function run_server()
  print(("rsnet-speed server  id=%d  modem=%s (%s side)"):format(my_id, kind, side))
  print("listening — Ctrl+T to stop.")
  local count, total = 0, 0
  local t_last_print = os.epoch("utc")
  while true do
    local id, msg = rednet.receive("rsnet-speed")
    if id then
      rednet.send(id, msg, "rsnet-speed")
      count = count + 1
      total = total + #tostring(msg)
      local now = os.epoch("utc")
      if now - t_last_print >= 1000 then
        print(("  echoed %d msgs (%s) — last from id=%d"):format(count, fmt_bytes(total), id))
        t_last_print = now
      end
    end
  end
end

--------------------------------------------------------------------------------
-- Client: time round-trip of N payloads.
--------------------------------------------------------------------------------

local function run_one(server, size, count)
  local payload = string.rep("X", size)
  local t0 = os.epoch("utc")
  local ok, latencies, min_lat, max_lat = 0, {}, math.huge, 0
  for i = 1, count do
    local mt0 = os.epoch("utc")
    rednet.send(server, payload, "rsnet-speed")
    local id, resp = rednet.receive("rsnet-speed", 5)
    local mdt = os.epoch("utc") - mt0
    if id == server and resp == payload then
      ok = ok + 1
      latencies[#latencies + 1] = mdt
      if mdt < min_lat then min_lat = mdt end
      if mdt > max_lat then max_lat = mdt end
    end
  end
  local dt_s = (os.epoch("utc") - t0) / 1000
  local bytes_one_way = ok * size
  local bytes_both    = ok * size * 2

  local avg_lat = 0
  for _, l in ipairs(latencies) do avg_lat = avg_lat + l end
  if #latencies > 0 then avg_lat = avg_lat / #latencies end

  return {
    size      = size,
    count     = count,
    ok        = ok,
    dt_s      = dt_s,
    bytes_one = bytes_one_way,
    bytes_two = bytes_both,
    rate_one  = bytes_one_way / dt_s,
    rate_two  = bytes_both / dt_s,
    msg_per_s = ok / dt_s,
    min_lat   = (min_lat == math.huge) and 0 or min_lat,
    max_lat   = max_lat,
    avg_lat   = avg_lat,
  }
end

local function print_result(r)
  print(("  %s × %d → %d/%d ok in %.2fs"):format(
    fmt_bytes(r.size), r.count, r.ok, r.count, r.dt_s))
  if r.ok == 0 then
    print("  all timed out — is the server running with the same protocol?")
    return
  end
  print(("    one-way throughput : %s"):format(fmt_rate(r.rate_one)))
  print(("    round-trip total   : %s"):format(fmt_rate(r.rate_two)))
  print(("    messages/s         : %.1f"):format(r.msg_per_s))
  print(("    latency  min/avg/max = %d/%.0f/%d ms"):format(
    r.min_lat, r.avg_lat, r.max_lat))
end

local function run_test(server, size, count)
  print(("rsnet-speed test  me=%d → server=%d  modem=%s"):format(my_id, server, kind))
  print(("  %d × %s payloads"):format(count, fmt_bytes(size)))
  local r = run_one(server, size, count)
  print_result(r)
end

local function run_sweep(server)
  print(("rsnet-speed sweep  me=%d → server=%d  modem=%s"):format(my_id, server, kind))
  local sizes = { 64, 256, 1024, 4096, 16384, 65535 }
  local counts = { 50, 50, 30, 20, 10, 5 }
  print(("  %-8s  %-6s  %-12s  %-10s  %-12s"):format(
    "size", "ok/n", "thrpt 1-way", "msg/s", "avg lat"))
  print("  --------  ------  ------------  ----------  ------------")
  for i, size in ipairs(sizes) do
    local r = run_one(server, size, counts[i])
    print(("  %-8s  %d/%-4d  %-12s  %-10.1f  %d ms"):format(
      fmt_bytes(size), r.ok, r.count, fmt_rate(r.rate_one),
      r.msg_per_s, math.floor(r.avg_lat + 0.5)))
  end
end

--------------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------------

local function usage()
  print("rsnet-speed — rednet bandwidth tester")
  print("usage:")
  print("  rsnet-speed server")
  print("  rsnet-speed test <server_id> [size_bytes=1024] [count=50]")
  print("  rsnet-speed sweep <server_id>")
end

if mode == "server" then
  run_server()
elseif mode == "test" then
  local server = tonumber(args[2])
  local size   = tonumber(args[3]) or 1024
  local count  = tonumber(args[4]) or 50
  if not server then usage() return end
  run_test(server, size, count)
elseif mode == "sweep" then
  local server = tonumber(args[2])
  if not server then usage() return end
  run_sweep(server)
else
  usage()
end
