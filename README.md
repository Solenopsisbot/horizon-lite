# Horizon Lite

**An unofficial, single-player-first fork of [Horizon](https://github.com/horizon-rust/horizon)** —
Minecraft: Java Edition 26.3, rewritten from scratch in Rust.

Horizon Lite is the game you know, with the product surfaces we do not want removed: no launcher,
no Microsoft account, no Realms, no telemetry service, no dedicated-server supervisor, no mod
registry, no release signing, no relay. One native binary, your own copy of Minecraft, your own
saves.

> **Not affiliated with Mojang Studios, Microsoft, or the Horizon project.** Minecraft is a
> trademark of Mojang Synergies AB. This repository contains no Minecraft code or assets; the game
> reads the files from your own installation. See [`NOTICE`](NOTICE).

## What is different from Horizon

| | Horizon | Horizon Lite |
|---|---|---|
| Launcher | GPUI launcher, Microsoft sign-in, self-update | None. `horizon-prepare` + `horizon-client` |
| Realms | Yes | Removed |
| Dedicated server | Yes (`horizon-server`) | Removed |
| Play with Friends / relay | Yes | Off by default (feature retained, not wired) |
| Mod registry, modpack porting, `cargo horizon-mod` | Yes | Removed |
| Telemetry ingest server, signed releases | Yes | Removed |
| Controllers, DualSense | On by default | Off by default |
| Horizon Settings, cosmetics, emotes, Discord, heartbeat | On by default | Off by default |
| Single player, LAN, all dimensions, mobs, redstone, command blocks | Yes | Yes |
| Resource packs, data packs, OptiFine models | Yes | Yes |
| Content mods, native Rust mods, shader packs | Yes | Present and unchanged in v0.1; removal is planned, see [`docs/lite/PLAN.md`](docs/lite/PLAN.md) |

The game is still ~1.27M lines of Rust. **Lite means fewer surfaces and a smaller build graph, not
a smaller Minecraft.** The full audit — what is cuttable, what is load-bearing, and why deleting
the network layer would break single player — is in [`docs/lite/PLAN.md`](docs/lite/PLAN.md).

## Build

Requirements: Rust 1.95+, JDK 25, Python 3.10+ (only for the prepare script), and on Linux
`libasound2-dev` + `libudev-dev`.

```sh
cargo build --release -p horizon-client -p horizon-prepare
```

### Prepare the game files (once per Minecraft version)

Horizon Lite never downloads Minecraft. It imports the copy you already own. Play 26.3 once in the
official launcher first, and have the 26.3 server jar ready.

```sh
./target/release/horizon-prepare --prepare --server-jar ~/Downloads/server.jar
./target/release/horizon-prepare sounds        # optional, ~380 MB of audio
```

This builds `.local/horizon-client/26.3` from your install, verifying it against
[`research-lock.json`](research-lock.json). It never writes to your Minecraft folder.

### Play

```sh
./target/release/horizon-client --resources .local/horizon-client/26.3 --world MyWorld
```

or use the wrapper:

```sh
./play.sh MyWorld
```

Single player needs no account and makes no network connection. Open to LAN works through the
in-process server; there is no internet service behind it.

### Verify a checkout

```sh
cargo check --workspace --all-targets
cargo check -p horizon-client --no-default-features   # no audio, no window features
cargo test -p horizon-client --lib
```

Enable the public-tree guard (rejects committed jars/assets) once per clone:

```sh
git config core.hooksPath .githooks
```

## Repository layout

| Path | What |
|---|---|
| `crates/horizon-client` | Game loop, gameplay, single-player server thread, `horizon-ctl` |
| `crates/horizon-client-render` | Chunks, meshing, light, GPU, HUD, screens |
| `crates/horizon-client-core`, `-input` | Text/lang/NBT, keybinds, window options |
| `crates/horizon-world` | Worldgen, NBT/regions, block behaviour, entity physics |
| `crates/horizon-core` | Java-exact math, RNG, positions, noise, paletted storage |
| `crates/horizon-protocol` | Protocol 777 codecs; **also single player's in-memory packet loop** |
| `crates/horizon-items`, `horizon-command`, `horizon-assets` | Blocks/items, Brigadier, model baking |
| `crates/horizon-prepare` | Builds the game's resources from your own Minecraft install |
| `mods/horizon/src/test/java` | The Java exporters `horizon-prepare` compiles (not tests) |
| `tools/native-hook-fragments` | **Build input** for the native mod API codegen |
| `tests/fixtures` | Three fixtures `include_str!`-ed by the client's test target |
| `docs/lite` | The teardown, the cut plan, and nine subsystem audits |

## License and attribution

MIT. The original Horizon copyright and license are preserved in [`LICENSE`](LICENSE). Third-party
notices, including the three patched crates in `third_party/`, are in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). This fork's own changes are additionally
covered by the same MIT terms.

The upstream project is at <https://github.com/horizon-rust/horizon>. This repository is a snapshot
of commit `4e6920a` with product surfaces removed; it is not a tracking fork and never opens pull
requests upstream.
