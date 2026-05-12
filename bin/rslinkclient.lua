-- rslinkclient — interactive dashboard for an rslink node.
--
-- Shows live stats, runs ping / speedtest against other nodes, and lets
-- you broadcast quick messages. Useful as both a diagnostic tool and a
-- minimal chat / control terminal.
--
-- Usage:
--   rslinkclient [my_id]
--
-- If my_id is not provided as an argument, the program will ask for one.

package.path = "/usr/allay/lib/?.lua;/usr/allay/lib/?/init.lua;" .. package.path
local rslink = require("rslink")
local config = rslink.config()

local args = { ... }
local my_id = tonumber(args[1])
if not my_id then
  write("Enter this node's id (1..254): ")
  my_id = tonumber(read())
end
if not my_id or my_id < config.MIN_NODE_ID or my_id > config.MAX_NODE_ID then
  error(("id must be %d..%d"):format(config.MIN_NODE_ID, config.MAX_NODE_ID), 0)
end

rslink.open(my_id)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function fmt_size(n)
  if n < 1024 then return n .. " B" end
  if n < 1024 * 1024 then return string.format("%.1f KB", n / 1024) end
  return string.format("%.2f MB", n / 1024 / 1024)
end

local has_color = term.isColor and term.isColor()
local function tcolor(c) if has_color then term.setTextColor(c) end end

local function draw_header()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  tcolor(colors.yellow)
  print(("rslink client  id=%d"):format(my_id))
  tcolor(colors.white)

  local s = rslink.stats()
  print()
  print("Stats:")
  print(("  tx: %d frames / %s"):format(s.tx_frames, fmt_size(s.tx_bytes)))
  print(("  rx: %d frames / %s"):format(s.rx_frames, fmt_size(s.rx_bytes)))
  print(("  ACK timeouts: %d   dup drops: %d   sym gaps: %d"):format(
    s.ack_timeouts, s.rx_dropped_dup, s.rx_symbol_gaps))
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local commands = {}

commands.help = function()
  print("Commands:")
  print("  help                   this list")
  print("  stats                  redraw stats")
  print("  ping <id> [n]          ping <id>, default 5 times")
  print("  speed <id> [bytes]     send 10 messages of <bytes> to <id>")
  print("  bcast <text>           broadcast a string")
  print("  listen [secs]          print incoming messages for N seconds (default 30)")
  print("  watch                  live stats loop; press any key to exit")
  print("  clear                  clear screen")
  print("  quit                   exit")
end

commands.stats = function() draw_header() end

commands.clear = function()
  term.setBackgroundColor(colors.black); term.clear(); term.setCursorPos(1, 1)
end

commands.ping = function(parts)
  local dst = tonumber(parts[2])
  local n   = tonumber(parts[3]) or 5
  if not dst then print("usage: ping <id> [n]") return end

  local ok_count, rtt_sum, rtt_min, rtt_max = 0, 0, math.huge, 0
  for i = 1, n do
    local t0 = os.epoch("utc")
    local ok = rslink.send(dst, "ping " .. i)
    if ok then
      local rtt = os.epoch("utc") - t0
      ok_count = ok_count + 1
      rtt_sum  = rtt_sum + rtt
      if rtt < rtt_min then rtt_min = rtt end
      if rtt > rtt_max then rtt_max = rtt end
      print(("  #%d: %d ms"):format(i, rtt))
    else
      print(("  #%d: TIMEOUT"):format(i))
    end
    os.sleep(0.1)
  end
  if ok_count > 0 then
    print(("ping stats: %d/%d ok   min/avg/max = %d/%d/%d ms"):format(
      ok_count, n, rtt_min, math.floor(rtt_sum / ok_count), rtt_max))
  else
    print("ping stats: all timed out")
  end
end

commands.speed = function(parts)
  local dst  = tonumber(parts[2])
  local size = tonumber(parts[3]) or 100
  if not dst then print("usage: speed <id> [bytes]") return end
  if size < 1 or size > 60000 then print("size 1..60000") return end

  local payload = string.rep("X", size)
  local N = 10
  print(("speed: sending %d messages of %d B to id %d..."):format(N, size, dst))
  local t0 = os.epoch("utc")
  local ok_count = 0
  for i = 1, N do
    if rslink.send(dst, payload) then ok_count = ok_count + 1 end
  end
  local dt    = (os.epoch("utc") - t0) / 1000
  local total = ok_count * size
  print(("  %d/%d msgs ACKed in %.2f s"):format(ok_count, N, dt))
  if ok_count > 0 then
    print(("  payload throughput: %s/s"):format(fmt_size(total / dt)))
  end
end

commands.bcast = function(parts)
  if not parts[2] then print("usage: bcast <text...>") return end
  local text = table.concat(parts, " ", 2)
  rslink.broadcast(text)
  print(("broadcast %d bytes"):format(#text))
end

commands.listen = function(parts)
  local secs = tonumber(parts[2]) or 30
  print(("listening for %d s. Ctrl+T to abort early."):format(secs))
  local end_t = os.epoch("utc") + secs * 1000
  while os.epoch("utc") < end_t do
    local from, msg, bcast = rslink.receive(0.5)
    if from then
      local tag = bcast and "[bcast]" or "[uni]"
      print(("  %s from %d: %s"):format(tag, from, tostring(msg)))
    end
  end
end

commands.watch = function()
  local timer = os.startTimer(0.5)
  while true do
    draw_header()
    print()
    tcolor(colors.lightGray); print("Watching. Press any key to exit."); tcolor(colors.white)
    local ev, a = os.pullEvent()
    if ev == "key" then
      os.cancelTimer(timer)
      return
    elseif ev == "timer" and a == timer then
      timer = os.startTimer(0.5)
    end
  end
end

commands.quit = function() error("__exit__", 0) end
commands.q    = commands.quit
commands.exit = commands.quit

--------------------------------------------------------------------------------
-- Main UI loop
--------------------------------------------------------------------------------

local function ui_loop()
  draw_header()
  print()
  commands.help()
  while true do
    tcolor(colors.lightGray); write("\n> "); tcolor(colors.white)
    local line = read()
    local parts = {}
    for w in line:gmatch("%S+") do parts[#parts + 1] = w end
    if parts[1] then
      local f = commands[parts[1]]
      if f then
        local ok, err = pcall(f, parts)
        if not ok then
          if err == "__exit__" then break end
          tcolor(colors.red); print("error: " .. tostring(err)); tcolor(colors.white)
        end
      else
        print("unknown: " .. parts[1] .. "  (type 'help')")
      end
    end
  end
end

rslink.host(my_id, ui_loop)

tcolor(colors.white)
print("rslink client exited.")
