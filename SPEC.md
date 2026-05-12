# rslink protocol spec — v1.1

A rednet-like wireless networking layer for CC: Tweaked built on Create's
Redstone Link network, via the [CC: Redstone Link Bridge](https://modrinth.com/mod/cc-redstone-link-bridge)
peripheral.

## The underlying primitive

```lua
local bridge = peripheral.find("redstone_link_bridge")

bridge.getLinkSignal(freq1, freq2)             -- read 0..15
bridge.sendLinkSignal(freq1, freq2, strength)  -- write 0..15
```

- `freq1` / `freq2` are item ID strings. Pairs are ordered: `(A,B) ≠ (B,A)`.
- Signal strength persists until overwritten (not pulsed).
- No events on change — polling only.
- A single bridge block reads/writes any pair on demand.

## Design decisions

| Decision | Value | Rationale |
|---|---|---|
| Topology | Half-duplex shared bus | Scales to unlimited nodes; classic rednet feel |
| Alphabet size | 16 items | 256 ordered pairs → ~1 KB/s |
| Lanes | 1 clock + 255 data | All 256 pairs used |
| Clock encoding | seq 0..14, **15 = sentinel** | Robust under yielding peripheral calls |
| Frame model | length-prefixed, CRC-16/CCITT | Strong enough for 256B frames |
| Frame size cap | 256B on the wire | Bounded retry granularity |
| Large messages | API-layer fragmentation | Invisible to caller |
| MAC | CSMA, random 5–30 tick backoff | Standard for shared bus |
| Optional RTS probe | config flag (default off) | For high-contention deployments |
| Reliability | ACK + retry for unicast | Like rednet; broadcast is best-effort |
| API shape | mirrors `rednet` | Existing code mostly drops in |

**Expected throughput**: ~1 KB/s usable, shared across senders. Half-duplex.

## Layer 0 — Physical

### Default alphabet (16 rare items)

```lua
ALPHABET = {
  "minecraft:nautilus_shell",         "minecraft:heart_of_the_sea",
  "minecraft:totem_of_undying",       "minecraft:dragon_breath",
  "minecraft:enchanted_golden_apple", "minecraft:end_crystal",
  "minecraft:conduit",                "minecraft:nether_star",
  "minecraft:elytra",                 "minecraft:trident",
  "minecraft:dragon_head",            "minecraft:sniffer_egg",
  "minecraft:echo_shard",             "minecraft:breeze_rod",
  "minecraft:music_disc_pigstep",     "minecraft:ominous_trial_key",
}
```

Picked to avoid collision with normal Create build frequencies. Several are
version-gated (sniffer_egg 1.20+, breeze_rod / ominous_trial_key 1.21+) —
swap for 1.20.1-compatible items if needed.

**Deployment rule**: before turning rslink on, sweep your world for existing
redstone-link pairs that use any item in your alphabet. A collision corrupts
the network *and* drives someone else's machine.

### Lane indexing

```lua
function pair_for_lane(lane)  -- lane ∈ [0, 255]
  local i = math.floor(lane / 16) + 1
  local j = (lane % 16) + 1
  return ALPHABET[i], ALPHABET[j]
end
```

- Lane `0` → clock lane (4-bit seq, see below)
- Lanes `1..255` → data lanes (4-bit nibble each)

## Layer 1 — Symbol transmission

Each symbol carries `255 × 4 = 1020 bits ≈ 127 bytes` of raw nibbles. After
stealing 1 byte for `SYMBOL_SEQ`, usable payload is **126 bytes/symbol**.

### Clock sentinel scheme

The clock value `15` is reserved as a sentinel "I am in the middle of writing
data lanes — don't read yet." Real sequence numbers cycle `0..14`.

This costs us one sequence-counter value but keeps the protocol correct even
if `sendLinkSignal` yields the coroutine mid-call (a real possibility in
CC: Tweaked).

### Transmit

`sendLinkSignal` yields the coroutine for ~1 tick per call (measured: exactly
50.000 ms/call sequential). Data-lane writes must be dispatched via
`parallel.waitForAll` to amortize the yield across one tick. Measured cost:
255 parallel calls = 2 ticks (~100 ms).

```lua
function transmit_symbol(nibbles)  -- nibbles[1..255]
  local cf1, cf2 = pair_for_lane(0)

  -- 1. Park clock at sentinel (1 tick)
  bridge.sendLinkSignal(cf1, cf2, 15)

  -- 2. Write all data lanes concurrently (~2 ticks via parallel)
  local fns = {}
  for lane = 1, 255 do
    fns[lane] = function()
      local f1, f2 = pair_for_lane(lane)
      bridge.sendLinkSignal(f1, f2, nibbles[lane] or 0)
    end
  end
  parallel.waitForAll(table.unpack(fns))

  -- 3. Publish real sequence number 0..14 (1 tick)
  current_seq = (current_seq + 1) % 15
  bridge.sendLinkSignal(cf1, cf2, current_seq)
end
```

The sentinel write and the real-seq write are not in the parallel batch
because their ordering matters: sentinel must land before data lanes change,
real_seq must land after they're all stable. Parallel dispatch within step 2
is safe because the receiver only latches when clock ≠ 15.

Symbol period: ~200 ms = 5 symbols/sec.

### Receive

```lua
function poll_loop()
  local cf1, cf2 = pair_for_lane(0)
  local last_seq = bridge.getLinkSignal(cf1, cf2)
  if last_seq == 15 then last_seq = nil end  -- bus busy at start; resync

  while true do
    os.sleep(0.05)
    local seq = bridge.getLinkSignal(cf1, cf2)
    if seq ~= 15 and seq ~= last_seq then
      local nibbles = {}
      for lane = 1, 255 do
        local f1, f2 = pair_for_lane(lane)
        nibbles[lane] = bridge.getLinkSignal(f1, f2)
      end
      last_seq = seq
      handle_symbol(nibbles)
    end
  end
end
```

## Layer 2 — Framing

Bytes pack big-endian into nibbles: `0xAB → [0xA, 0xB]`. An N-byte frame
consumes `2N` nibbles. Frame payload is capped at 256B on the wire.

### Symbol header (1 byte at lanes 1–2)

```
SYMBOL_SEQ (1 byte) | ... frame data ...
```

`SYMBOL_SEQ` cycles 0..255 per sender. Receivers track expected next
`SYMBOL_SEQ` per source and abort any in-progress frame on gap, resyncing
on the next `START` byte.

### Frame layout

```
| START 0xA5 | SRC | DST | SEQ | LEN (2B LE) | PAYLOAD (LEN B) | CRC16 (2B LE) |
```

- `START` — magic sync byte `0xA5`
- `SRC` — sender ID, 1..254
- `DST` — receiver ID, 1..254, or 255 (broadcast)
- `SEQ` — sender's per-recipient seq (0..255, rolls over). Used for ACK match
  and dedup.
- `LEN` — payload length in bytes, little-endian. **Max 256.**
- `PAYLOAD` — raw bytes (Lua values serialized via `textutils.serialize`)
- `CRC16` — CRC-16/CCITT (polynomial `0x1021`, init `0xFFFF`) over header
  + payload, little-endian.

Frames > 126 bytes span multiple symbols; the symbol header's `SYMBOL_SEQ`
makes gap detection cheap. The API layer fragments user messages larger
than the on-wire frame cap.

## Layer 3 — MAC

Half-duplex shared bus → multiple senders can collide.

1. **Carrier sense.** Sample the clock lane for 3 ticks. If it changed, the
   bus is busy → random 5–30 tick backoff, retry.
2. **Claim.** If idle, begin transmitting (sentinel → data → real seq).
3. **Read-back collision detect** *(optional, config flag)*. After each
   `sendLinkSignal`, read it back. If read > written, another node is also
   transmitting → abort, random backoff, retry. Unreliable when concurrent
   writers happen to send the same value; rely on CRC + retry as the
   primary backstop.
4. **Optional RTS probe** *(config flag, default off)*. Sender writes
   `clock=14` for 2 ticks then reads back. If it sees `15`, someone else
   is also probing → both back off. Kills the simultaneous-sense-idle
   race for high-contention deployments at a cost of 100ms latency.

## Layer 4 — Reliability

**Unicast** (DST ≠ 255):
- Sender waits for ACK from DST within 500 ms.
- ACK = frame with `LEN=0`, payload empty, `SEQ` matching original.
- On timeout: retry up to 3 times with exponential backoff (100/200/400 ms).
- Receivers dedup by `(SRC, SEQ)`, window 16 most-recent per source.

**Broadcast** (DST = 255):
- No ACK, no retry. Best-effort.
- Receivers may dedup with a shorter window or not at all.

## Layer 5 — User API

```lua
local rslink = require("rslink")

rslink.open(myId, { alphabet = ALPHABET, peripheral_name = nil })

local ok = rslink.send(destId, message, timeoutSec)   -- blocks until ACK
rslink.broadcast(message)                              -- fire-and-forget
local from, msg, bcast = rslink.receive(timeoutSec)

-- Or by event:
-- os.pullEvent("rslink_message") → "rslink_message", fromId, message, isBroadcast

rslink.close()
```

`message` is any serializable Lua value. The library handles fragmentation
of large messages above the 256B on-wire cap, transparently.

A polling coroutine driven by `parallel` calls `os.queueEvent("rslink_message", ...)`
so user code's `os.pullEvent` integrates naturally.

## Upgrade path

**v2: per-sender clock lanes.** Drops the shared-clock aliasing risk entirely
at the cost of bounded node count. Flag config flip; v1 protocol stays
available.

**v2+:** multi-hop routing, encryption/auth (frequency hopping + HMAC),
heartbeat/health monitoring.

## Open questions

| Test | Question | Result |
|---|---|---|
| `test_yield` | Does `sendLinkSignal` yield? | **Yes — exactly 1 tick / call sequential.** |
| `test_parallel_yield` | Does `parallel.waitForAll` amortize? | **Yes — 255 calls in 2 ticks.** |
| `test_self_propagation` | Self read-after-write latency? | 0 ticks (instant). |
| `test_cross_send` + `_recv` | Cross-bridge propagation T? | **T = 2 ticks (100 ms) consistently.** |
| `test_concurrent_writer` + `_reader` | Aggregation rule? | **MAX (300/300 reads saw 7 with writers at 3 and 7).** |

All open questions resolved. Spec is locked; read-back collision detection
in the MAC layer is viable.

## Numbers (T=2, parallel-amortized writes)

| Metric | Value |
|---|---|
| Items reserved | 16 |
| Frequency pairs used | 256 / 256 |
| `sendLinkSignal` cost (sequential) | 50 ms / call (1 tick) |
| `sendLinkSignal` cost (255 parallel) | ~100 ms (2 ticks) |
| Symbol period | 200 ms (sentinel + parallel data + real-seq) |
| Symbols/sec | 5 |
| Bytes per symbol (after SYMBOL_SEQ) | 126 |
| Raw throughput | ~0.63 KB/s |
| Useful throughput (after framing) | ~0.6 KB/s |
| Max payload per frame (on wire) | 256 B |
| Max user message | unbounded (API fragments) |
| ACK timeout (default) | 500 ms |
| Max retries (default) | 3 |
| Backoff window (default) | 5–30 ticks |
