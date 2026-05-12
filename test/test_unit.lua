-- test_unit.lua
-- Pure-Lua unit tests for rslink.resolver and rslink.frame.
-- Run on any computer; no redstone_link_bridge required.

package.path = "/usr/allay/lib/?.lua;/usr/allay/lib/?/init.lua;" .. package.path

local resolver = require("rslink.resolver")
local config   = require("rslink.config")
local frame    = require("rslink.frame")

local passed, failed = 0, 0
local function expect(actual, expected, label)
  if actual == expected then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL: %s: got %s, want %s"):format(label, tostring(actual), tostring(expected)))
  end
end

----------------------------------------------------------------------
print("-- resolver --")
----------------------------------------------------------------------

do
  local a, b = resolver.pair_for_lane(0)
  expect(a, config.ALPHABET[1], "lane 0 f1")
  expect(b, config.ALPHABET[1], "lane 0 f2")
end

do
  local a, b = resolver.pair_for_lane(255)
  expect(a, config.ALPHABET[16], "lane 255 f1")
  expect(b, config.ALPHABET[16], "lane 255 f2")
end

do
  local a, b = resolver.pair_for_lane(17)
  expect(a, config.ALPHABET[2], "lane 17 f1")
  expect(b, config.ALPHABET[2], "lane 17 f2")
end

do
  local all_ok = true
  for lane = 0, 255 do
    local a, b = resolver.pair_for_lane(lane)
    if resolver.lane_for_pair(a, b) ~= lane then all_ok = false; break end
  end
  expect(all_ok, true, "all 256 lanes round-trip")
end

----------------------------------------------------------------------
print("-- frame: bytes/nibbles --")
----------------------------------------------------------------------

do
  local nibbles = frame.bytes_to_nibbles({ 0x12, 0xAB, 0xFF })
  expect(nibbles[1], 0x1, "0x12 high")
  expect(nibbles[2], 0x2, "0x12 low")
  expect(nibbles[3], 0xA, "0xAB high")
  expect(nibbles[4], 0xB, "0xAB low")
  expect(nibbles[5], 0xF, "0xFF high")
  expect(nibbles[6], 0xF, "0xFF low")
  local back = frame.nibbles_to_bytes(nibbles)
  expect(back[1], 0x12, "0x12 back")
  expect(back[2], 0xAB, "0xAB back")
  expect(back[3], 0xFF, "0xFF back")
end

----------------------------------------------------------------------
print("-- frame: CRC-16/CCITT --")
----------------------------------------------------------------------

do
  local crc = frame.crc16(frame.str_to_bytes("123456789"))
  expect(crc, 0x29B1, "CRC-16/CCITT('123456789') = 0x29B1 (known answer)")
end

do
  local crc = frame.crc16({})
  expect(crc, 0xFFFF, "CRC of empty input")
end

----------------------------------------------------------------------
print("-- frame: encode/decode --")
----------------------------------------------------------------------

do
  local bytes = frame.encode_frame(42, 100, 7, "hello world")
  local off, f = frame.try_decode_frame(bytes, 1)
  expect(type(f), "table", "decode produced frame")
  expect(f.src, 42, "src")
  expect(f.dst, 100, "dst")
  expect(f.seq, 7, "seq")
  expect(f.payload, "hello world", "payload")
  expect(off, #bytes + 1, "consumed all bytes")
end

do
  -- Empty payload (used for ACK frames)
  local bytes = frame.encode_frame(1, 2, 3, "")
  local off, f = frame.try_decode_frame(bytes, 1)
  expect(off, #bytes + 1, "ack consumed")
  expect(f.payload, "", "ack empty payload")
end

do
  -- Frame after garbage
  local fb = frame.encode_frame(9, 9, 9, "yo")
  local buf = { 0x00, 0xFF, 0x37 }
  for i = 1, #fb do buf[#buf + 1] = fb[i] end
  local off, f = frame.try_decode_frame(buf, 1)
  expect(f.src, 9, "src after junk prefix")
  expect(f.payload, "yo", "payload after junk prefix")
end

do
  -- Corruption is caught
  local bytes = frame.encode_frame(42, 100, 7, "hello world")
  bytes[8] = (bytes[8] + 1) % 256   -- mangle a payload byte
  local off, err = frame.try_decode_frame(bytes, 1)
  expect(off, nil, "corrupted decode returns nil")
  expect(err, "bad_crc", "error type")
end

do
  -- Max payload
  local big = string.rep("x", 256)
  local bytes = frame.encode_frame(1, 2, 0, big)
  local off, f = frame.try_decode_frame(bytes, 1)
  expect(f.payload, big, "256-byte payload round-trip")
end

do
  -- Partial buffer → need_more
  local bytes = frame.encode_frame(1, 2, 0, "abcdef")
  local partial = {}
  for i = 1, #bytes - 3 do partial[i] = bytes[i] end
  local off, err = frame.try_decode_frame(partial, 1)
  expect(off, nil, "partial returns nil")
  expect(err, "need_more", "need_more on truncated buffer")
end

do
  -- drain_frames handles two concatenated frames
  local f1 = frame.encode_frame(1, 2, 0, "first")
  local f2 = frame.encode_frame(3, 4, 1, "second")
  local buf = {}
  for _, b in ipairs(f1) do buf[#buf + 1] = b end
  for _, b in ipairs(f2) do buf[#buf + 1] = b end
  local frames, new_off = frame.drain_frames(buf, 1)
  expect(#frames, 2, "drained two frames")
  expect(frames[1].payload, "first", "first payload")
  expect(frames[2].payload, "second", "second payload")
  expect(new_off, #buf + 1, "drained fully")
end

----------------------------------------------------------------------
print()
if failed == 0 then
  print(("ALL %d ASSERTIONS PASSED"):format(passed))
else
  print(("%d passed, %d FAILED"):format(passed, failed))
  error("unit tests failed", 0)
end
