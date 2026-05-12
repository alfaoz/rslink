-- wheel-angle — read a Create Speedometer, display live RPM and the
-- integrated steering angle on an attached monitor. Press R in the
-- computer's terminal to zero the angle, Q to quit.
--
-- Install (after the GitHub CDN refreshes, ~5 min):
--   wget https://raw.githubusercontent.com/alfaoz/rslink/main/bin/wheel-angle.lua wheel-angle
--
-- Hardware:
--   * Create Speedometer on the steering shaft (directly attached, or
--     reachable through a wired modem)
--   * Monitor attached to the computer
--
-- Run:
--   wheel-angle

local MAX_ANGLE = 540   -- degrees from center; tune to your wheel's range

----------------------------------------------------------------------
-- Peripherals
----------------------------------------------------------------------

local function find_speedometer()
  for _, side in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(side)
    if p and p.getSpeed then
      return p, side
    end
  end
  return nil
end

local speedo, speedo_side = find_speedometer()
if not speedo then
  printError("no Speedometer found.")
  print("attach a Create Speedometer (directly or via a wired modem) and rerun.")
  return
end

local monitor = peripheral.find("monitor")
if not monitor then
  printError("no monitor found.")
  print("attach a monitor (directly or via a wired modem) and rerun.")
  return
end

monitor.setTextScale(1)

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local angle  = 0
local last_t = os.epoch("utc") / 1000

----------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------

local function centered(y, text, color)
  local w, _ = monitor.getSize()
  local x = math.max(1, math.floor((w - #text) / 2) + 1)
  monitor.setCursorPos(x, y)
  monitor.setTextColor(color or colors.white)
  monitor.write(text)
end

local function draw(rpm)
  local w, h = monitor.getSize()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()

  -- Title + status dot
  monitor.setCursorPos(2, 1)
  monitor.setTextColor(colors.gray)
  monitor.write("wheel-angle")
  monitor.setCursorPos(w - 1, 1)
  monitor.setTextColor(math.abs(rpm) > 0.01 and colors.yellow or colors.lime)
  monitor.write("o")

  local cy = math.floor(h / 2)

  -- Steering bar
  if w >= 10 then
    local bar_y = cy - 1
    local bar_w = w - 4
    monitor.setCursorPos(3, bar_y)
    monitor.setTextColor(colors.gray)
    monitor.write(string.rep("-", bar_w))

    local cx = 3 + math.floor(bar_w / 2)
    monitor.setCursorPos(cx, bar_y)
    monitor.setTextColor(colors.white)
    monitor.write("|")

    local norm = math.max(-1, math.min(1, angle / MAX_ANGLE))
    local mx   = cx + math.floor((bar_w / 2) * norm)
    mx = math.max(3, math.min(2 + bar_w, mx))
    monitor.setCursorPos(mx, bar_y)
    monitor.setTextColor(math.abs(rpm) > 0.01 and colors.yellow or colors.lime)
    monitor.write("X")
  end

  centered(cy + 1, string.format("ANG  %+8.1f deg", angle), colors.white)
  centered(cy + 3, string.format("RPM  %+7.1f",     rpm),   colors.cyan)

  if h >= 5 then
    centered(h, "press R to zero  Q to quit", colors.gray)
  end
end

----------------------------------------------------------------------
-- Coroutines
----------------------------------------------------------------------

local function sampler()
  while true do
    local now = os.epoch("utc") / 1000
    local dt  = now - last_t
    last_t = now

    local rpm = speedo.getSpeed()
    -- 1 RPM = 6 deg/sec
    angle = angle + rpm * 6 * dt
    if angle >  MAX_ANGLE then angle =  MAX_ANGLE end
    if angle < -MAX_ANGLE then angle = -MAX_ANGLE end

    draw(rpm)
    os.sleep(0.05)
  end
end

local function input_handler()
  while true do
    local _, key = os.pullEvent("key")
    if key == keys.r then
      angle = 0
    elseif key == keys.q then
      return
    end
  end
end

----------------------------------------------------------------------
-- Run
----------------------------------------------------------------------

term.clear() term.setCursorPos(1, 1)
print("wheel-angle running")
print(("  speedometer : %s"):format(speedo_side))
print(("  monitor     : %s"):format(peripheral.getName(monitor)))
print(("  range       : +/- %d deg"):format(MAX_ANGLE))
print("")
print("press R to zero the angle")
print("press Q to quit")

parallel.waitForAny(sampler, input_handler)

monitor.setBackgroundColor(colors.black)
monitor.clear()
monitor.setCursorPos(1, 1)
monitor.setTextColor(colors.white)
term.clear() term.setCursorPos(1, 1)
print("wheel-angle stopped.")
