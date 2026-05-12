-- pose-probe — dump everything CC: Sable knows about this computer's
-- current pose so we can figure out why orientation reads as identity.
--
-- Install (cache-busted):
--   wget "https://raw.githubusercontent.com/alfaoz/rslink/main/bin/pose-probe.lua?nocache=1" pose-probe
--
-- Run on the physics-object computer:
--   pose-probe

local sub = _G.sublevel or sublevel
if not sub then
  printError("no sublevel global — CC: Sable not installed?")
  return
end

local function dump(label, v, depth)
  depth = depth or 0
  local pad = string.rep("  ", depth)
  local t = type(v)
  if t == "nil" or t == "string" or t == "number" or t == "boolean" then
    print(("%s%s = %s (%s)"):format(pad, label, tostring(v), t))
  elseif t == "function" then
    print(("%s%s = <function>"):format(pad, label))
  elseif t == "table" then
    print(("%s%s = {"):format(pad, label))
    local any = false
    for k, val in pairs(v) do
      any = true
      dump(tostring(k), val, depth + 1)
    end
    if not any then print(("%s  -- empty table"):format(pad)) end
    print(("%s}"):format(pad))
    local mt = getmetatable(v)
    if mt then
      print(("%s  -- metatable:"):format(pad))
      for k in pairs(mt) do print(("%s    %s"):format(pad, tostring(k))) end
    end
  else
    print(("%s%s = <%s>"):format(pad, label, t))
  end
end

local function section(name)
  print("")
  print("== " .. name .. " ==")
end

section("identity")
local ok, v = pcall(sub.getUniqueId); print("getUniqueId():", ok, tostring(v))
ok, v = pcall(sub.getName);     print("getName():    ", ok, tostring(v))

section("getLogicalPose")
ok, v = pcall(sub.getLogicalPose)
if ok and v then
  dump("logicalPose", v)
else
  print("error:", tostring(v))
end

section("getLastPose")
ok, v = pcall(sub.getLastPose)
if ok and v then
  dump("lastPose", v)
else
  print("error:", tostring(v))
end

section("velocities")
ok, v = pcall(sub.getVelocity);        print("getVelocity():       ", ok, textutils.serialize(v))
ok, v = pcall(sub.getLinearVelocity);  print("getLinearVelocity(): ", ok, textutils.serialize(v))
ok, v = pcall(sub.getAngularVelocity); print("getAngularVelocity():", ok, textutils.serialize(v))

section("mass / inertia")
ok, v = pcall(sub.getMass);        print("getMass():       ", ok, tostring(v))
ok, v = pcall(sub.getInverseMass); print("getInverseMass():", ok, tostring(v))
ok, v = pcall(sub.getCenterOfMass);print("getCenterOfMass():", ok, textutils.serialize(v))

print("")
print("-- end of probe --")
