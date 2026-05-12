# rslink

Rednet-like wireless networking for [CC: Tweaked](https://tweaked.cc), built
on [Create](https://www.curseforge.com/minecraft/mc-mods/create)'s redstone
link network instead of ender modems, via the [CC: Redstone Link Bridge](https://modrinth.com/mod/cc-redstone-link-bridge)
peripheral.

**Status:** spec frozen, in-game timing tests landing first. No library code
yet. The three tests in `tests/` answer load-bearing questions about
`sendLinkSignal` semantics before any framing code gets written.

## Dependencies

- [CC: Tweaked](https://tweaked.cc/)
- [Create](https://www.curseforge.com/minecraft/mc-mods/create)
- [CC: Redstone Link Bridge](https://modrinth.com/mod/cc-redstone-link-bridge)

## Running the tests

One-line install on any in-game computer with `http` enabled:

```
wget run https://raw.githubusercontent.com/alfaoz/rslink/main/install_tests.lua
```

This drops six test scripts in `/rslink-tests/`. Or grab individual files:

```
wget https://raw.githubusercontent.com/alfaoz/rslink/main/tests/test_yield.lua
wget https://raw.githubusercontent.com/alfaoz/rslink/main/tests/test_parallel_yield.lua
wget https://raw.githubusercontent.com/alfaoz/rslink/main/tests/test_self_propagation.lua
wget https://raw.githubusercontent.com/alfaoz/rslink/main/tests/test_cross_send.lua
wget https://raw.githubusercontent.com/alfaoz/rslink/main/tests/test_cross_recv.lua
wget https://raw.githubusercontent.com/alfaoz/rslink/main/tests/test_concurrent_writer.lua
wget https://raw.githubusercontent.com/alfaoz/rslink/main/tests/test_concurrent_reader.lua
```

### The three tests, and what they answer

#### 1. `test_yield` — does `sendLinkSignal` yield?

Setup: one computer, one redstone link bridge.

Times 255 sequential `sendLinkSignal` calls. Empirical result on the
reference setup: **exactly 50.000 ms/call** — every call yields the coroutine
for one Minecraft tick. 255 calls = 12.75 s. The "write data lanes, then
bump clock" invariant is preserved by the sentinel pattern, but the sequential
per-sender throughput ceiling is 4 bits / 50 ms = **80 bps**.

That makes `test_parallel_yield` the pivotal next test.

#### 1b. `test_parallel_yield` — does `parallel.waitForAll` amortize?

If 255 coroutines each issue one `sendLinkSignal` and their yields overlap
within a single tick, throughput is recoverable to the spec's ~1 KB/s.
If the mod serializes calls regardless, the 80 bps ceiling holds and
the spec needs a redesign for skinnier symbols.

The test sweeps N ∈ {1, 16, 64, 255} so partial amortization is visible.

#### 2. `test_self_propagation` + `test_cross_send`/`test_cross_recv` — propagation delay

Self-propagation: one computer, one bridge. Writes a value, reads it back at
0/1/2/3/4 tick delays. Smallest consistent delay is single-bridge
read-after-write latency.

Cross-propagation: two computers, two bridges, same frequency pair.
- Start `test_cross_recv` first (polls every tick, timestamps every transition).
- Then run `test_cross_send` (writes 30 distinct values, timestamps each write).

For each `[i]` line, `(recv_t - send_t) / 50` is the propagation latency in
ticks. This sets `T` in the spec, which determines the symbol period and the
final throughput numbers.

#### 3. `test_concurrent_writer` + `test_concurrent_reader` — aggregation semantics

Three computers, three bridges, same frequency pair.
- Computer A: `test_concurrent_writer 3`
- Computer B: `test_concurrent_writer 7`
- Computer C: `test_concurrent_reader`

Reader prints a histogram and an interpretation:

| Histogram | Meaning | Spec impact |
|-----------|---------|-------------|
| only `7` | MAX aggregation | Spec stands. Read-back collision detection works. |
| only `3` | MIN aggregation | Spec needs review. |
| mix of `3` and `7` | last-writer-wins | Read-back collision detect is unreliable; lean on CRC + retry. |
| `10` or other | SUM or unknown | Redesign needed. |

Run all three before writing any framing code.

## Spec

See [`SPEC.md`](./SPEC.md) for the full protocol spec — alphabet, lane
allocation, framing, CRC, MAC, reliability, API shape. Highlights:

- 16-item alphabet, 256 ordered frequency pairs (1 clock + 255 data lanes)
- `clock=15` sentinel; real sequence numbers cycle 0..14
- CRC-16/CCITT, frames capped at 256B on wire (API fragments larger messages)
- Symbol header byte `SYMBOL_SEQ` for gap detection across symbols
- CSMA with 5–30 tick backoff; optional RTS-style probe behind a config flag
- rednet-shaped API: `open/send/broadcast/receive/close`, `rslink_message` events

### Default alphabet caveat

The spec's default alphabet uses items that don't collide with typical
Create build frequencies:

```
nautilus_shell, heart_of_the_sea, totem_of_undying, dragon_breath,
enchanted_golden_apple, end_crystal, conduit, nether_star,
elytra, trident, dragon_head, sniffer_egg,
echo_shard, breeze_rod, music_disc_pigstep, ominous_trial_key
```

Several of these are version-gated:

- `sniffer_egg` — 1.20+
- `echo_shard` — 1.19+
- `breeze_rod`, `ominous_trial_key` — 1.21+

For Minecraft 1.20.1 (where Create is most common today), swap the last
three for any other rare items in your modpack (e.g. mod-namespaced
gadgets). The tests use only `nautilus_shell` + `heart_of_the_sea`
(both 1.13+), so they run on any modern version.

Either way: **before deploying, sweep your world for any existing
redstone-link pair using items from your alphabet**. A collision will
both corrupt your network and drive someone's sorter.

## Packaging

We'll ship as an [allay](https://github.com/allaycc/allay) package once
there's a stable library to install. Current `wget` install is fine for the
test phase.

## License

MIT.
