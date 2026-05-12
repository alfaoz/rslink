-- test_pingpong_a.lua
-- Half 1 of the loopback test. Run on computer A with a bridge.
-- Sends "ping N" to peer (id 2), waits for "pong N" back.
-- The reply round-trip exercises encode→MAC→symbol→bridge→symbol→decode→
-- reassemble→event→send→encode→... in both directions.

package.path = "/usr/allay/lib/?.lua;/usr/allay/lib/?/init.lua;" .. package.path
local rslink = require("rslink")

local PEER  = 2
local N     = 5
local MY_ID = 1

rslink.open(MY_ID)
print(("rslink id=%d open; peer=%d"):format(MY_ID, PEER))

local function main()
  for i = 1, N do
    local msg = "ping " .. i
    io.write(("send #%d: %q ... "):format(i, msg))
    local ok = rslink.send(PEER, msg)
    if not ok then
      print("ACK TIMEOUT")
    else
      print("ACKed; waiting for reply...")
      local from, reply, bcast = rslink.receive(2)
      if from then
        print(("  reply from %d: %q"):format(from, tostring(reply)))
      else
        print("  no reply within 2s")
      end
    end
    os.sleep(0.5)
  end

  print()
  print("Stats:")
  local s = rslink.stats()
  for k, v in pairs(s) do print(("  %s = %s"):format(k, tostring(v))) end
  rslink.close()
end

rslink.host(MY_ID, main)
