-- wheel-angle-sable — read the contraption's own orientation via the
-- CC: Sable Sub-Level API and display roll/pitch/yaw on an attached
-- monitor.
--
-- The Sub-Level API is exposed by CC: Sable as a GLOBAL named `sublevel`
-- (not a peripheral). It is only populated when the computer is on a
-- Sable Sub-Level (i.e. inside an assembled physics contraption such as
-- one mounted on a Create: Aeronautics swivel bearing).
--
-- Install (after the GitHub CDN refreshes, ~5 min):
--   wget https://raw.githubusercontent.com/alfaoz/rslink/main/bin/wheel-angle-sable.lua wheel-angle-sable
--
-- Keys (in the computer terminal):
--   R    zero the currently-featured axis
--   TAB  cycle which axis is featured on the bar
--   Q    quit

----------------------------------------------------------------------
-- API discovery: sublevel is a global Lua table installed by CC: Sable
----------------------------------------------------------------------

local sub = _G.sublevel or sublevel
if not sub or type(sub.getLogicalPose) ~= "function" then
  printError("CC: Sable 'sublevel' API not available.")
  print("Make sure CC: Sable is installed, and that this computer is on")
  print("an ASSEMBLED Sable contraption (the swivel bearing must be")
  print("right-clicked to assemble before the API is wired up).")
  return
end

local monitor = peripheral.find("monitor")
if not monitor then
  printError("no monitor found — attach one to the computer.")
  return
end
monitor.setTextScale(1)

----------------------------------------------------------------------
-- Quaternion → Euler (degrees). Handles several conventions for the
-- CC: Advanced Math quaternion object so we don't have to guess.
----------------------------------------------------------------------

local function quat_to_euler(q)
  if not q then return 0, 0, 0 end

  -- Convention A: object exposes a toEulerAngles() returning radians.
  if type(q.toEulerAngles) == "function" then
    local ok, e = pcall(q.toEulerAngles, q)
    if ok and e then
      local rx = e.x or e[1] or e.roll  or 0
      local ry = e.y or e[2] or e.pitch or 0
      local rz = e.z or e[3] or e.yaw   or 0
      return math.deg(rx), math.deg(ry), math.deg(rz)
    end
  end

  -- Convention B: dedicated component getters.
  if type(q.getYaw) == "function" then
    local ok_r, r = pcall(q.getRoll,  q)
    local ok_p, p = pcall(q.getPitch, q)
    local ok_y, y = pcall(q.getYaw,   q)
    if ok_r and ok_p and ok_y then
      return math.deg(r), math.deg(p), math.deg(y)
    end
  end

  -- Convention C: raw w/x/y/z, either as fields, accessors, or array.
  local w, x, y, z
  if type(q.w) == "number" then
    w, x, y, z = q.w, q.x, q.y, q.z
  elseif type(q.getW) == "function" then
    local ok_w, ok_x, ok_y, ok_z = pcall(q.getW, q), pcall(q.getX, q), pcall(q.getY, q), pcall(q.getZ, q)
    w, x, y, z = q.getW(q), q.getX(q), q.getY(q), q.getZ(q)
  elseif type(q[1]) == "number" then
    w, x, y, z = q[1], q[2], q[3], q[4]
  end
  if type(w) ~= "number" then return 0, 0, 0 end

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
local ok, uuid = pcall(sub.getUniqueId)
local ok2, name = pcall(sub.getName)
print("wheel-angle (sable) running")
if ok  then print(("  sub-level uuid : %s"):format(tostring(uuid))) end
if ok2 then print(("  sub-level name : %s"):format(tostring(name))) end
print(("  monitor        : %s"):format(peripheral.getName(monitor)))
print("")
print("R     zero the featured axis")
print("TAB   cycle which axis is featured")
print("Q     quit")

parallel.waitForAny(sampler, input_handler)

monitor.setBackgroundColor(colors.black)
monitor.clear()
term.clear() term.setCursorPos(1, 1)
print("wheel-angle (sable) stopped.")
