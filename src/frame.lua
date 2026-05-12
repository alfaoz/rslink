-- rslink.frame — bytes ↔ nibbles, CRC-16/CCITT, frame encode/decode.
--
-- Frame on wire (all bytes):
--   | START 0xA5 | SRC | DST | SEQ | LEN_LO | LEN_HI | PAYLOAD (LEN B) | CRC_LO | CRC_HI |
-- CRC-16/CCITT (poly 0x1021, init 0xFFFF, no reflection, no XOR-out)
-- is computed over bytes [1..6+LEN] inclusive (header + payload).

local M = {}

-- Bit ops. CC: Tweaked ships bit32 natively; host Lua 5.3+ doesn't.
local band, bor, bxor, lshift, rshift
if bit32 then
  band, bor, bxor, lshift, rshift =
    bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift
else
  band   = load("return function(a,b) return a & b end")()
  bor    = load("return function(a,b) return a | b end")()
  bxor   = load("return function(a,b) return a ~ b end")()
  lshift = load("return function(a,n) return (a << n) & 0xFFFFFFFF end")()
  rshift = load("return function(a,n) return a >> n end")()
end

--------------------------------------------------------------------------------
-- CRC-16/CCITT
--------------------------------------------------------------------------------

function M.crc16(bytes, start_idx, end_idx)
  start_idx = start_idx or 1
  end_idx = end_idx or #bytes
  local crc = 0xFFFF
  for i = start_idx, end_idx do
    crc = bxor(crc, lshift(bytes[i], 8))
    for _ = 1, 8 do
      if band(crc, 0x8000) ~= 0 then
        crc = band(bxor(lshift(crc, 1), 0x1021), 0xFFFF)
      else
        crc = band(lshift(crc, 1), 0xFFFF)
      end
    end
  end
  return crc
end

--------------------------------------------------------------------------------
-- Bytes ↔ nibbles (big-endian: high nibble first)
--------------------------------------------------------------------------------

function M.bytes_to_nibbles(bytes, out)
  out = out or {}
  local k = #out
  for i = 1, #bytes do
    local b = bytes[i]
    out[k + 1] = rshift(b, 4)
    out[k + 2] = band(b, 0x0F)
    k = k + 2
  end
  return out
end

function M.nibbles_to_bytes(nibbles, count)
  count = count or math.floor(#nibbles / 2)
  local bytes = {}
  for i = 1, count do
    local hi = nibbles[2 * i - 1] or 0
    local lo = nibbles[2 * i] or 0
    bytes[i] = lshift(hi, 4) + lo
  end
  return bytes
end

--------------------------------------------------------------------------------
-- String ↔ byte array
--------------------------------------------------------------------------------

function M.str_to_bytes(s)
  local bytes = {}
  for i = 1, #s do
    bytes[i] = string.byte(s, i)
  end
  return bytes
end

function M.bytes_to_str(bytes, start_idx, end_idx)
  start_idx = start_idx or 1
  end_idx = end_idx or #bytes
  local chars = {}
  for i = start_idx, end_idx do
    chars[i - start_idx + 1] = string.char(bytes[i])
  end
  return table.concat(chars)
end

--------------------------------------------------------------------------------
-- Frame encode / decode
--------------------------------------------------------------------------------

-- encode_frame(src, dst, seq, payload_str) → byte array
function M.encode_frame(src, dst, seq, payload_str)
  local n = #payload_str
  if n > 256 then
    error("payload too large: " .. n .. " bytes (max 256)", 2)
  end

  local bytes = {}
  bytes[1] = 0xA5
  bytes[2] = src
  bytes[3] = dst
  bytes[4] = seq
  bytes[5] = band(n, 0xFF)
  bytes[6] = band(rshift(n, 8), 0xFF)

  for i = 1, n do
    bytes[6 + i] = string.byte(payload_str, i)
  end

  local crc = M.crc16(bytes, 1, 6 + n)
  bytes[7 + n] = band(crc, 0xFF)
  bytes[8 + n] = band(rshift(crc, 8), 0xFF)

  return bytes
end

-- try_decode_frame(bytes, offset) →
--   next_offset, frame   — frame parsed; consumed up to next_offset
--   nil, "no_start"      — no START byte found from offset onward
--   nil, "need_more"     — START found but not enough bytes yet
--   nil, "bad_crc"       — START found but CRC mismatch (caller slides +1)
--   nil, "bad_frame"     — START found but length field invalid (caller slides +1)
function M.try_decode_frame(bytes, offset)
  offset = offset or 1

  while offset <= #bytes and bytes[offset] ~= 0xA5 do
    offset = offset + 1
  end
  if offset > #bytes then return nil, "no_start" end

  if #bytes - offset + 1 < 6 then return nil, "need_more" end

  local src = bytes[offset + 1]
  local dst = bytes[offset + 2]
  local seq = bytes[offset + 3]
  local len = bytes[offset + 4] + lshift(bytes[offset + 5], 8)

  if len > 256 then return nil, "bad_frame" end

  if #bytes - offset + 1 < 6 + len + 2 then return nil, "need_more" end

  local crc_pos  = offset + 6 + len
  local got_crc  = bytes[crc_pos] + lshift(bytes[crc_pos + 1], 8)
  local want_crc = M.crc16(bytes, offset, crc_pos - 1)
  if got_crc ~= want_crc then return nil, "bad_crc" end

  local frame = {
    src     = src,
    dst     = dst,
    seq     = seq,
    payload = M.bytes_to_str(bytes, offset + 6, offset + 5 + len),
  }
  return offset + 6 + len + 2, frame
end

-- Repeatedly call try_decode_frame, sliding past bad frames.
-- Returns: list of frames, new_offset.
-- new_offset is where the partial / unparsed tail begins.
function M.drain_frames(bytes, offset)
  offset = offset or 1
  local frames = {}
  while true do
    local next_off, f_or_err = M.try_decode_frame(bytes, offset)
    if next_off then
      frames[#frames + 1] = f_or_err
      offset = next_off
    elseif f_or_err == "need_more" then
      break
    elseif f_or_err == "no_start" then
      offset = #bytes + 1
      break
    else  -- bad_crc, bad_frame
      offset = offset + 1
    end
  end
  return frames, offset
end

return M
