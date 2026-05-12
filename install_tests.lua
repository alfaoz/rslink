-- install_tests.lua
-- Downloads the rslink test scripts to /rslink-tests/ on this computer.
-- Run with:
--   wget run https://raw.githubusercontent.com/alfaoz/rslink/main/install_tests.lua

local BASE = "https://raw.githubusercontent.com/alfaoz/rslink/main/tests/"
local DEST = "/rslink-tests"
local FILES = {
  "test_yield.lua",
  "test_parallel_yield.lua",
  "test_self_propagation.lua",
  "test_cross_send.lua",
  "test_cross_recv.lua",
  "test_concurrent_writer.lua",
  "test_concurrent_reader.lua",
}

print("rslink test suite installer")
print("Target: " .. DEST .. "/")
print()

if not fs.exists(DEST) then fs.makeDir(DEST) end

local ok, fail = 0, 0
for _, name in ipairs(FILES) do
  io.write("  " .. name .. " ... ")
  local resp, err = http.get(BASE .. name)
  if not resp then
    print("FAIL (" .. tostring(err) .. ")")
    fail = fail + 1
  else
    local body = resp.readAll()
    resp.close()
    local f, oerr = fs.open(DEST .. "/" .. name, "w")
    if not f then
      print("FAIL (" .. tostring(oerr) .. ")")
      fail = fail + 1
    else
      f.write(body)
      f.close()
      print("ok")
      ok = ok + 1
    end
  end
end

print()
print(("Installed %d/%d files."):format(ok, #FILES))
if fail > 0 then
  print(("%d failed - check http connectivity and try again."):format(fail))
  return
end

print()
print("Quick start (cd to the test dir first):")
print("  cd " .. DEST)
print("  test_yield                    -- one computer, one bridge")
print("  test_parallel_yield           -- one computer, one bridge")
print("  test_self_propagation         -- one computer, one bridge")
print()
print("Cross-bridge propagation (2 computers, 2 bridges, same freq pair):")
print("  receiver: test_cross_recv     -- start FIRST")
print("  sender:   test_cross_send")
print()
print("Concurrent write (3 computers, 3 bridges, same freq pair):")
print("  writer A: test_concurrent_writer 3")
print("  writer B: test_concurrent_writer 7")
print("  reader  : test_concurrent_reader   -- start AFTER both writers")
