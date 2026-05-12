# rslink

Rednet-shaped wireless networking for [CC: Tweaked](https://tweaked.cc),
built on [Create](https://www.curseforge.com/minecraft/mc-mods/create)'s
redstone link network instead of ender modems, via the
[CC: Redstone Link Bridge](https://modrinth.com/mod/cc-redstone-link-bridge)
peripheral.

**Status:** v0.1, library and apps shipped. Throughput ~0.6 KB/s usable per
sender, 5 symbols/sec, half-duplex shared bus. See [`SPEC.md`](./SPEC.md) for
the protocol; numbers below are validated by in-game tests in `tests/`.

## Dependencies

- [CC: Tweaked](https://tweaked.cc/)
- [Create](https://www.curseforge.com/minecraft/mc-mods/create) (1.19+ for the default alphabet)
- [CC: Redstone Link Bridge](https://modrinth.com/mod/cc-redstone-link-bridge)

## Install — easy path (via allay)

If you don't have allay yet:

```
wget run https://raw.githubusercontent.com/allaycc/allay/main/install.lua
```

Then add the rslink source and install the suite:

```
allay source add alfaoz/getrslink
allay install rslink-suite
```

That installs three things:

- **rslink** — the library. `require("rslink")` from your own programs.
- **rslinkclient** — interactive dashboard: stats, ping, speedtest, broadcast, listen.
- **rslinkview** — 16×16 lane visualizer with activity decay.

## Install — direct path (no allay)

```
wget https://raw.githubusercontent.com/alfaoz/rslink/main/bin/rslinkclient.lua
wget https://raw.githubusercontent.com/alfaoz/rslink/main/bin/rslinkview.lua
# and the library files, into /usr/allay/lib/rslink/ or similar
```

The allay route is strongly preferred — the library has 7 files and they
need to be in a `require`-able location.

## Quick start

On a computer with a `redstone_link_bridge` peripheral attached:

```lua
local rslink = require("rslink")

rslink.open(42)

rslink.host(42, function()
  rslink.broadcast("hello, world")
  while true do
    local from, msg, bcast = rslink.receive()
    print(("[%s] from %d: %s"):format(bcast and "bcast" or "uni", from, tostring(msg)))
  end
end)
```

## API (mirrors rednet)

```lua
rslink.open(my_id, opts)        -- my_id ∈ 1..254
rslink.send(dst, message)       -- unicast; blocks until ACK; returns ok
rslink.broadcast(message)       -- fire-and-forget
rslink.receive(timeout_s)       -- → from_id, message, is_broadcast (or nil)
rslink.close()

-- Convenience:
rslink.host(my_id, user_main)   -- opens (if needed), parallel.waitForAny
rslink.run()                    -- the rx loop, for manual parallel setups

-- Observability:
rslink.stats()   -- tx_frames, tx_bytes, rx_frames, rx_bytes, ACK timeouts,
                 -- dup drops, symbol-seq gaps
rslink.id()
rslink.is_open()
rslink.config()  -- alphabet, defaults
```

`os.pullEvent("rslink_message")` returns `from_id, message, is_broadcast`.

Messages can be any value `textutils.serialize` accepts. The library
transparently fragments anything up to ~63 KB across multiple frames with
per-fragment ACK + retry.

## Apps

### rslinkclient

```
rslinkclient [my_id]
```

A dashboard with ping, speedtest, broadcast, and live stats. Press `help`
for the command list once it's running.

### rslinkview

```
rslinkview
```

A 16×16 grid where each cell is one of the 256 (i, j) frequency pairs
rslink uses. Cells light up when their pair carries signal; intensity
decays over time so traffic looks like fading trails. The clock lane
(top-left) is shown in yellow; the `SENTINEL` value is purple.

## Coexistence with normal Create redstone-link wiring

A bridge can read/write any frequency pair on demand — rslink only
*uses* the 256 pairs built from its 16-item alphabet. Pairs outside that
set (e.g. `iron_ingot ↔ gold_ingot`) are not touched, so existing Create
machines on other frequencies keep working untouched while rslink runs.

Before deploying: sweep your world for any redstone-link transmitter or
receiver that uses items from the rslink alphabet (or override the alphabet
via `rslink.open(id, { alphabet = { ... } })` if you have conflicts).

## Tests

Two layers of test in this repo:

- **`tests/`** — in-game timing tests that validate the protocol's
  assumptions on a real Minecraft world. Run via the bootstrap installer
  below or `wget` individual scripts. These were used to discover the
  parallel-dispatch requirement and the 5 sym/s throughput.

- **`test/`** — library tests (unit + integration). Installed as part of
  the package; not auto-run.

Bootstrap the timing tests:

```
wget run https://raw.githubusercontent.com/alfaoz/rslink/main/install_tests.lua
```

Run the unit tests after installing the library:

```
lua /usr/allay/lib/rslink/test_unit.lua    # (if shipped); or just
require("rslink") -- and call rslink layers manually
```

## Spec

See [`SPEC.md`](./SPEC.md) for the protocol — alphabet, lane allocation,
sentinel clock, framing, CRC, MAC, reliability, API shape. Highlights:

- 16-item alphabet, 256 ordered frequency pairs (1 clock + 255 data lanes)
- `clock=15` sentinel; real sequence numbers cycle 0..14
- CRC-16/CCITT, frames capped at 256 B on wire (API fragments larger messages)
- Symbol header byte `SYMBOL_SEQ` for gap detection across symbols
- CSMA with 5–30 tick backoff
- rednet-shaped API: `open/send/broadcast/receive/close`, `rslink_message` events

## License

MIT.
