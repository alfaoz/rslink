-- wheel-angle-sable — read the contraption's own orientation via CC: Sable
-- (Create: Avionics / Sable Sub-Level API) and display roll / pitch / yaw
-- on an attached monitor.
--
-- Install (after the GitHub CDN refreshes, ~5 min):
--   wget https://raw.githubusercontent.com/alfaoz/rslink/main/bin/wheel-angle-sable.lua wheel-angle-sable
--
-- Setup:
--   * Place the computer on a contraption mounted on a Swivel Bearing
--   * Assemble the contraption so it becomes a Sable Sub-Level
--   * Attach a monitor to the computer
--
-- Run:
--   wheel-angle-sable
--
-- Keys (in the computer terminal):
--   R    zero the currently-featured axis
--   TAB  cycle which axis is featured on the bar
--   Q    quit

----------------------------------------------------------------------
-- Peripherals
----------------------------------------------------------------------

local function find_sublevel()
  for _, side in ipairs(peripheral.getNames()) do
    local p = peripheral.wrap(side)
    if p and type(p.getLogicalPose) == "function" then
      return p, side
    end
  end
  return nil
end

local sub, sub_side = find_sublevel()
if not sub then
  printError("no Sub-Level peripheral found.")
  print("required: CC: Sable / Create: Avionics installed, AND the computer")
  print("must be on an assembled Sable contraption (not in the static world).")
  return
end

local monitor = peripheral.find("monitor")
if not monitor then
  printError("no monitor found.")
  print("attach a monitor to the computer (directly or via wired modem).")
  return
end

monitor.setTextScale(1)

----------------------------------------------------------------------
-- Quaternion → Euler angles (degrees)
--   tries the CC: Advanced Math API first, falls back to raw fields.
----------------------------------------------------------------------

local function quat_to_euler(q)
  if not q then return 0, 0, 0 end

  if type(q.toEulerAngles) == "function" then
    local e = q.toEulerAngles()
    if e then
      local rx = e.x or e[1] or e.roll  or 0
      local ry = e.y or e[2] or e.pitch or 0
      local rz = e.z or e[3] or e.yaw   or 0
      return math.deg(rx), math.deg(ry), math.deg(rz)
    end
  end

  local w, x, y, z
  if type(q.w) == "number" then
    w, x, y, z = q.w, q.x, q.y, q.z
  elseif type(q.getW) == "function" then
    w, x, y, z = q.getW(), q.getX(), q.getY(), q.getZ()
  elseif type(q[1]) == "number" then
    w, x, y, z = q[1], q[2], q[3], q[4]
  end
  if not w then return 0, 0, 0 end

  local roll  = math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
  local sinp  = 2 * (w * y - z * x)
  local pitch = (math.abs(sinp) >= 1)
                  and (sinp >= 0 and math.pi / 2 or -math.pi / 2)
                  or  math.asin(sinp)
  local yaw   = math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
  return math.deg(roll), math.deg(pitch), math.deg(yaw)
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local axes      = { "roll", "pitch", "yaw" }
local axis_idx  = 3
local offset    = { roll = 0, pitch = 0, yaw = 0 }

local function read_raw()
  local pose = sub.getLogicalPose()
  if not pose then return 0, 0, 0 end
  return quat_to_euler(pose.orientation)
end

local function read_with_offset()
  local r, p, y = read_raw()
  return r - offset.roll, p - offset.pitch, y - offset.yaw
end

local function normalize(a)
  while a >  180 do a = a - 360 end
  while a < -180 do a = a + 360 end
  return a
end

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

local function draw()
  local roll, pitch, yaw = read_with_offset()
  roll, pitch, yaw = normalize(roll), normalize(pitch), normalize(yaw)
  local values = { roll = roll, pitch = pitch, yaw = yaw }
  local axis   = axes[axis_idx]
  local val    = values[axis]

  local w, h = monitor.getSize()
  monitor.setBackgroundColor(colors.black)
  monitor.clear()

  monitor.setCursorPos(2, 1)
  monitor.setTextColor(colors.gray)
  monitor.write("wheel-angle (sable)")

  local cy = math.floor(h / 2)

  if w >= 10 then
    local bar_y = cy - 2
    local bar_w = w - 4
    monitor.setCursorPos(3, bar_y)
    monitor.setTextColor(colors.gray)
    monitor.write(string.rep("-", bar_w))
    local cx = 3 + math.floor(bar_w / 2)
    monitor.setCursorPos(cx, bar_y)
    monitor.setTextColor(colors.white)
    monitor.write("|")
    local norm = math.max(-1, math.min(1, val / 180))
    local mx = cx + math.floor((bar_w / 2) * norm)
    mx = math.max(3, math.min(2 + bar_w, mx))
    monitor.setCursorPos(mx, bar_y)
    monitor.setTextColor(colors.yellow)
    monitor.write("X")
  end

  centered(cy,     string.format("%s  %+7.1f deg", axis:upper(), val), colors.yellow)
  centered(cy + 2, string.format("roll   %+7.1f",  roll),  axis_idx == 1 and colors.yellow or colors.gray)
  centered(cy + 3, string.format("pitch  %+7.1f",  pitch), axis_idx == 2 and colors.yellow or colors.gray)
  centered(cy + 4, string.format("yaw    %+7.1f",  yaw),   axis_idx == 3 and colors.yellow or colors.gray)

  if h >= 6 then
    centered(h, "R zero  TAB axis  Q quit", colors.gray)
  end
end

----------------------------------------------------------------------
-- Coroutines
----------------------------------------------------------------------

local function sampler()
  while true do
    draw()
    os.sleep(0.05)
  end
end

local function input_handler()
  while true do
    local _, key = os.pullEvent("key")
    if key == keys.r then
      local r, p, y = read_raw()
      local axis = axes[axis_idx]
      if axis == "roll"  then offset.roll  = r end
      if axis == "pitch" then offset.pitch = p end
      if axis == "yaw"   then offset.yaw   = y end
    elseif key == keys.tab then
      axis_idx = (axis_idx % #axes) + 1
    elseif key == keys.q then
      return
    end
  end
end

----------------------------------------------------------------------
-- Run
----------------------------------------------------------------------

term.clear() term.setCursorPos(1, 1)
print("wheel-angle (sable) running")
print(("  sub-level : %s"):format(sub_side))
print(("  monitor   : %s"):format(peripheral.getName(monitor)))
print("")
print("R     zero the featured axis")
print("TAB   cycle which axis is featured")
print("Q     quit")

parallel.waitForAny(sampler, input_handler)

monitor.setBackgroundColor(colors.black)
monitor.clear()
term.clear() term.setCursorPos(1, 1)
print("wheel-angle (sable) stopped.")
