-- tilt — live roll/pitch/yaw readout of this CC: Sable sub-level on an
-- attached monitor. Decodes the CC: Advanced Math quaternion correctly
-- (the {a, v} shape, where a is the scalar and v is the {x, y, z}
-- vector part). Press R to zero the featured axis, TAB to cycle which
-- axis is featured, Q to quit.
--
-- Install:
--   wget https://raw.githubusercontent.com/alfaoz/rslink/main/bin/tilt.lua tilt
-- Run:
--   tilt

local sub = _G.sublevel or sublevel
if not sub or type(sub.getLogicalPose) ~= "function" then
  printError("sublevel API not present — install CC: Sable.")
  return
end

local monitor = peripheral.find("monitor")
if not monitor then
  printError("no monitor attached.")
  return
end
monitor.setTextScale(1)

----------------------------------------------------------------------
-- Quaternion handling
----------------------------------------------------------------------

local function extract_wxyz(q)
  if type(q) ~= "table" then return nil end
  if type(q.a) == "number" and type(q.v) == "table" then
    local v = q.v
    local x = v.x or v[1]
    local y = v.y or v[2]
    local z = v.z or v[3]
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then
      return q.a, x, y, z
    end
  end
  if type(q.w) == "number" and type(q.x) == "number" then
    return q.w, q.x, q.y, q.z
  end
  if type(q[1]) == "number" then
    return q[1], q[2], q[3], q[4]
  end
  return nil
end

local function quat_to_euler_deg(w, x, y, z)
  if type(w) ~= "number" then return 0, 0, 0 end
  local roll = math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
  local sinp = 2 * (w * y - z * x)
  local pitch = (math.abs(sinp) >= 1)
                and (sinp >= 0 and math.pi / 2 or -math.pi / 2)
                or math.asin(sinp)
  local yaw = math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
  return math.deg(roll), math.deg(pitch), math.deg(yaw)
end

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local axes      = { "roll", "pitch", "yaw" }
local axis_idx  = 2   -- default: pitch (the user's wand-tilt axis)
local offset    = { roll = 0, pitch = 0, yaw = 0 }

local function read_raw()
  local ok, pose = pcall(sub.getLogicalPose)
  if not ok or not pose then return 0, 0, 0 end
  local w, x, y, z = extract_wxyz(pose.orientation)
  return quat_to_euler_deg(w, x, y, z)
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
  local w = monitor.getSize()
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
  monitor.write("tilt")

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

term.clear() term.setCursorPos(1, 1)
print("tilt running")
print("monitor: " .. peripheral.getName(monitor))
print("")
print("R   zero featured axis")
print("TAB cycle axis (roll/pitch/yaw)")
print("Q   quit")

parallel.waitForAny(sampler, input_handler)

monitor.setBackgroundColor(colors.black)
monitor.clear()
term.clear() term.setCursorPos(1, 1)
print("tilt stopped.")
