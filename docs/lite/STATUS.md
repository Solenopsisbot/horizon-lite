# Status — v0.1

Date: 2026-11-08. Fork base: upstream `4e6920a` (2026-11-08).

## Verified

| Check | Command | Result |
|---|---|---|
| Whole workspace, all targets | `cargo check --workspace --all-targets` | **pass** |
| Headless/server profile | `cargo check -p horizon-client --no-default-features` | **pass** |
| Default build profile | `default = ["audio"]` in `horizon-client` and `horizon-client-lib` | **pass** |
| Toolchain | `rustc 1.99.1`, `cargo 1.99.1`, Linux x86-64 | — |
| CI `verify` (GitHub Actions, `ubuntu-latest`) | format + workspace check + no-default check + `cargo test -p horizon-client --lib` | **pass**, 7m47s at `b84991f` |

The local machine was simultaneously building another checkout, so a full
`cargo build --profile fast` was OOM-killed twice there. GitHub's runner compiled and linked the
library test target and ran 1,144 tests (1,143 passed, 212 ignored for missing prepared
resources, 1 failed only on the previous run and removed). The gameplay executable's link and a
runtime smoke test are still unverified — see below.

## Not yet verified

- **Runtime smoke test.** Needs `.local/horizon-client/26.3` produced by `horizon-prepare` from a
  real Minecraft 26.3 install plus JDK 25. Not available in the build environment used for v0.1.
- **The `horizon-client` executable's link.** CI checks all targets and links the library test
  target, but does not link the release executable (the release build job was removed: public
  runners are not upstream's self-hosted release pool).
- **Visual check.** No GPU/window session; the title screen layout changes (Realms removed,
  Options/Quit moved up one row) have not been seen on screen.
- **Save round-trip.** Unchanged code, but not exercised here.
- **LAN.** Unchanged code, but not exercised here.

If you are the first to run this: build with `cargo build --profile fast -p horizon-client`, run
`horizon-prepare` once, then `./play.sh TestWorld` and report what the log says.

## What changed

See [`PLAN.md` §2](PLAN.md#2-what-v01-removed). Short list:

- Removed: launcher, Realms, dedicated-server supervisor, mod registry, modpack porting, relay,
  bots, telemetry ingest server, release signing, the dead `polytone` crate, 1,101 tool scripts,
  the Python test infra, upstream docs/media/benchmarks/roadmap.
- Default build no longer includes controllers or `horizon-extras` (cosmetics, Discord, friends,
  heartbeat, official server list, Horizon Settings page).
- Kept: single player (in-process server thread), LAN, all dimensions, mobs, redstone, commands,
  resource/data packs, content mods and shader packs (off by default), agent control.

## Known gaps and sharp edges

1. **Parity is frozen.** The 569 differential harnesses and Java oracles are gone. No change can be
   proven against vanilla 26.3 any more. [`PLAN.md` §5.4](PLAN.md#54-parity-is-gone-and-that-is-a-real-loss).
2. **`horizon-extras` still compiles most of the code it "disables".** It has four `cfg!` sites.
   The default build hides the UI but links the modules. Deleting them is v0.2 work.
3. **The dedicated-server code is still inside the client** (`game/dedicated*`, 5.1k). The
   supervisor crate is gone; the `--dedicated` entry point is not.
4. **Telemetry client code remains.** There is no ingest server, no launcher collecting consent,
   and no heartbeat in the default build, but `horizon-telemetry` is still linked for crash-report
   system info. Do not describe the build as "telemetry-free" until that crate is split; describe
   it as "no telemetry upload path".
5. **`horizon-prepare` needs JDK 25 and a real 26.3 install.** The precompiled `exporters/` bundle
   that releases ship is not in this repo. A source-only fork must compile them locally.
6. **The `lite` name is a product promise, not a size claim.** ~1.27M lines of Rust remain.
7. **`xtask package-server` was removed with the supervisor.** `xtask package` still builds a
   playable folder.

## Next

The ordered next steps are in [`PLAN.md` §4](PLAN.md#4-what-is-still-cuttable-ranked) and the
commit table in §6. Recommended v0.2: dev/agent harnesses, multiplayer-only UI, in-game dedicated
code, cosmetics/extras UI, shader-pack loader.
