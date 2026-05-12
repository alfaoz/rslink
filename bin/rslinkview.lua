-- rslinkview — live 16×16 lane visualizer for an rslink bus.
--
-- Polls all 256 (i, j) frequency pairs every ~tick (in parallel) and draws
-- a grid where each cell's intensity is the current signal strength on that
-- pair, decaying when no traffic. The clock lane (top-left, "0,0") and the
-- sentinel value are colored separately.
--
-- Requires the rslink library installed (uses its alphabet + lane indexing
-- so what you see matches what rslink uses).

package.path = "/usr/allay/lib/?.lua;/usr/allay/lib/?/init.lua;" .. package.path

local config = require("rslink.config")

local bridge = peripheral.find("redstone_link_bridge")
if not bridge then
  error("attach a redstone_link_bridge peripheral first", 0)
end

local ALPHABET = config.ALPHABET
local SENTINEL = config.CLOCK_SENTINEL
local has_color = term.isColor and term.isColor()

-- Pre-build the (f1, f2) pair table once. Avoids math in the hot poll loop.
local PAIRS = {}
for lane = 0, 255 do
  local i = math.floor(lane / 16) + 1
  local j = (lane % 16) + 1
  PAIRS[lane] = { ALPHABET[i], ALPHABET[j] }
end

-- activity[lane] is the displayed value (0..15), max-merged with new reads
-- and decremented each frame to make traffic visible as fading trails.
local activity = {}
for lane = 0, 255 do activity[lane] = 0 end

local function poll_all()
  local read = {}
  local fns = {}
  for lane = 0, 255 do
    local p = PAIRS[lane]
    fns[lane + 1] = function()
      read[lane] = bridge.getLinkSignal(p[1], p[2])
    end
  end
  parallel.waitForAll(table.unpack(fns))
  return read
end

-- Symbol counter — based on the RAW clock reading, not the decayed activity
-- (which pegs near 15 under sustained traffic and never transitions cleanly).
local last_raw_clock  = -1
local sym_count_acc   = 0
local sym_per_sec     = 0
local last_window_t   = os.epoch("utc")

local function update(read)
  -- Step the symbol counter off the raw clock read.
  local c = read[0]
  if c ~= SENTINEL and c ~= last_raw_clock then
    sym_count_acc = sym_count_acc + 1
    last_raw_clock = c
  end
  local now = os.epoch("utc")
  if now - last_window_t >= 1000 then
    sym_per_sec   = sym_count_acc
    sym_count_acc = 0
    last_window_t = now
  end

  for lane = 0, 255 do
    local r = read[lane] or 0
    if r > activity[lane] then
      activity[lane] = r
    elseif activity[lane] > 0 then
      activity[lane] = activity[lane] - 1
    end
  end
end

local function char_for(v)
  if v == 0  then return " " end
  if v <= 3  then return "." end
  if v <= 7  then return "+" end
  if v <= 11 then return "*" end
  return "#"
end

local function color_for(v, is_clock)
  if is_clock then
    if v == SENTINEL then return colors.purple end
    if v > 0 then return colors.yellow end
    return colors.gray
  end
  if v == 0  then return colors.gray end
  if v <= 3  then return colors.blue end
  if v <= 7  then return colors.cyan end
  if v <= 11 then return colors.lime end
  return colors.yellow
end

local function draw()

  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.white)
  term.clear()

  -- Row 1: header
  term.setCursorPos(1, 1)
  local clock = activity[0]
  local clock_label = (clock == SENTINEL) and "SENT" or tostring(clock)
  term.write(("rslink view   clock=%s   sym/s=%d"):format(clock_label, sym_per_sec))

  -- Row 2: column labels (low nibble j)
  term.setCursorPos(3, 2)
  term.setTextColor(colors.lightGray)
  term.write("0123456789ABCDEF")

  -- Rows 3..18: grid (high nibble i)
  for row = 0, 15 do
    term.setCursorPos(1, 3 + row)
    term.setTextColor(colors.lightGray)
    term.write(string.format("%X ", row))
    for col = 0, 15 do
      local lane = row * 16 + col
      local v = activity[lane]
      if has_color then
        term.setTextColor(color_for(v, lane == 0))
      end
      term.write(char_for(v))
    end
  end

  -- Row 19: footer
  term.setCursorPos(1, 19)
  term.setTextColor(colors.white)
  term.write("q quit | . + * # = activity | clock yellow | sentinel purple")
end

local function key_poll()
  while true do
    local _, k = os.pullEvent("key")
    if k == keys.q then return end
  end
end

local function loop()
  while true do
    update(poll_all())
    draw()
    os.sleep(0.05)
  end
end

parallel.waitForAny(loop, key_poll)

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
print("rslinkview exited.")
