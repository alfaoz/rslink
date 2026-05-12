-- test_pingpong_b.lua
-- Half 2 of the loopback test. Run on computer B with a bridge.
-- Listens for messages and echoes them back with "ping" replaced by "pong".

package.path = "/usr/allay/lib/?.lua;/usr/allay/lib/?/init.lua;" .. package.path
local rslink = require("rslink")

local MY_ID = 2
rslink.open(MY_ID)
print(("rslink id=%d open; waiting for messages"):format(MY_ID))

local function main()
  while true do
    local from, msg, bcast = rslink.receive()
    print(("got from %d (%s): %q"):format(
      from, bcast and "broadcast" or "unicast", tostring(msg)))
    if type(msg) == "string" then
      local reply = (msg:gsub("ping", "pong"))
      rslink.send(from, reply)
    end
  end
end

rslink.host(MY_ID, main)
