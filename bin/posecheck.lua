-- posecheck — pretty, one-screen readout of a CC: Sable sub-level pose.
-- Replaces the earlier pose-probe dump with a layout that fits a default
-- CC terminal so the result is readable in-game.
--
-- Install:
--   wget https://raw.githubusercontent.com/alfaoz/rslink/main/bin/posecheck.lua posecheck
-- Run:
--   posecheck

local sub = _G.sublevel or sublevel
if not sub then
  printError("no sublevel global. install CC: Sable.")
  return
end

----------------------------------------------------------------------
-- Quaternion → (w, x, y, z, methods-found)
----------------------------------------------------------------------

local function extract_wxyz(q)
  if type(q) ~= "table" then return nil end
  -- CC: Advanced Math quaternion: { a = scalar, v = vector{x,y,z} }
  if type(q.a) == "number" and type(q.v) == "table" then
    local v = q.v
    local x = v.x or v[1]
    local y = v.y or v[2]
    local z = v.z or v[3]
    if type(x) == "number" and type(y) == "number" and type(z) == "number" then
      return q.a, x, y, z, "{a, v}"
    end
  end
  if type(q.w) == "number" and type(q.x) == "number" then
    return q.w, q.x, q.y, q.z, "fields"
  end
  if type(q.getW) == "function" then
    local ok_w, w = pcall(q.getW, q)
    local ok_x, x = pcall(q.getX, q)
    local ok_y, y = pcall(q.getY, q)
    local ok_z, z = pcall(q.getZ, q)
    if ok_w and ok_x and ok_y and ok_z then
      return w, x, y, z, "getW/getX/..."
    end
  end
  if type(q[1]) == "number" then
    return q[1], q[2], q[3], q[4], "array"
  end
  return nil, nil, nil, nil, "unknown"
end

local function quat_to_euler_deg(w, x, y, z)
  if type(w) ~= "number" then return nil, nil, nil end
  local roll = math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y))
  local sinp = 2 * (w * y - z * x)
  local pitch = (math.abs(sinp) >= 1)
                and (sinp >= 0 and math.pi / 2 or -math.pi / 2)
                or math.asin(sinp)
  local yaw = math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
  return math.deg(roll), math.deg(pitch), math.deg(yaw)
end

local function is_identity(w, x, y, z)
  if type(w) ~= "number" then return false end
  local eps = 0.0005
  return math.abs(w - 1) < eps
     and math.abs(x)     < eps
     and math.abs(y)     < eps
     and math.abs(z)     < eps
end

local function fmt_n(n)
  if type(n) ~= "number" then return "?" end
  return string.format("%+0.4f", n)
end

local function fmt_vec(v)
  if type(v) ~= "table" then return tostring(v) end
  local x = v.x or v[1]; local y = v.y or v[2]; local z = v.z or v[3]
  return string.format("(%s, %s, %s)", fmt_n(x), fmt_n(y), fmt_n(z))
end

----------------------------------------------------------------------
-- Read both poses
----------------------------------------------------------------------

local function safe(fn)
  local ok, v = pcall(fn)
  if ok then return v end
  return nil, v
end

local lp,  lp_err = safe(sub.getLogicalPose)
local lap, lap_err = safe(sub.getLastPose)
local av,  av_err = safe(sub.getAngularVelocity)
local uuid = safe(sub.getUniqueId)
local name = safe(sub.getName)

----------------------------------------------------------------------
-- Pretty print
----------------------------------------------------------------------

local function hr()
  print(string.rep("-", 40))
end

local function print_pose(label, pose, err)
  print(label)
  if not pose then
    print("  (error: " .. tostring(err) .. ")")
    return
  end
  print("  pos     " .. fmt_vec(pose.position))
  local w, x, y, z, how = extract_wxyz(pose.orientation)
  if w == nil then
    print("  ori     <unrecognized> shape=" .. how)
    print("  ori type: " .. type(pose.orientation))
    if type(pose.orientation) == "table" then
      for k, v in pairs(pose.orientation) do
        print(("  ori  .%-12s = %s"):format(tostring(k), tostring(v)))
      end
    end
    return
  end
  print(("  ori     w=%s x=%s"):format(fmt_n(w), fmt_n(x)))
  print(("          y=%s z=%s   [%s]"):format(fmt_n(y), fmt_n(z), how))
  local r, p, ya = quat_to_euler_deg(w, x, y, z)
  print(("  euler   roll=%+7.1f"):format(r or 0/0))
  print(("          pitch=%+7.1f"):format(p or 0/0))
  print(("          yaw  =%+7.1f"):format(ya or 0/0))
  if is_identity(w, x, y, z) then
    print("  ** IDENTITY: pose API thinks this sub-level is NOT rotated **")
  end
end

term.clear() term.setCursorPos(1, 1)
print("posecheck — Sable sub-level pose")
hr()
print(("uuid : %s"):format(tostring(uuid)))
print(("name : %s"):format(tostring(name)))
hr()
print_pose("LOGICAL pose:", lp, lp_err)
hr()
print_pose("LAST pose:",    lap, lap_err)
hr()
print(("angVel : %s"):format(fmt_vec(av)))
