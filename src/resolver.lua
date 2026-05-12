-- rslink.resolver — map lane indices to ordered frequency pairs.
--
-- A 16-item alphabet yields 256 ordered (i, j) pairs. Lane 0 is the clock
-- lane; lanes 1..255 are data lanes. Indexing is linear (no hashing) —
-- at this density there's nothing to hash against.

local config = require("rslink.config")

local M = {}

-- pair_for_lane(lane) → (f1, f2)  for lane ∈ [0, 255]
function M.pair_for_lane(lane, alphabet)
  alphabet = alphabet or config.ALPHABET
  local i = math.floor(lane / 16) + 1
  local j = (lane % 16) + 1
  return alphabet[i], alphabet[j]
end

-- lane_for_pair((f1, f2)) → lane,  for sanity-checking and debugging.
function M.lane_for_pair(f1, f2, alphabet)
  alphabet = alphabet or config.ALPHABET
  local i, j
  for k, v in ipairs(alphabet) do
    if v == f1 then i = k - 1 end
    if v == f2 then j = k - 1 end
  end
  if not i or not j then return nil end
  return i * 16 + j
end

return M
