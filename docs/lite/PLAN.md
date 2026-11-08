# Horizon Lite — what to remove, what to keep, and why

This is the design document for `horizon-lite`: an unofficial, single-player-first fork of
[Horizon](https://github.com/horizon-rust/horizon), the Minecraft Java 26.3 reimplementation in
Rust. It records what we audited, what we removed in v0.1, what is still on the table, and which
cuts are traps.

The raw audits are in [`reports/`](reports/). They were produced read-only against upstream
`4e6920a` by nine parallel agents, one per subsystem. Every LOC figure below is measured, not
estimated.

---

## 0. The snapshot

| | Upstream `4e6920a` | `horizon-lite` v0.1 | Δ |
|---|---:|---:|---:|
| Rust, game workspace (`crates/` + `xtask/`) | 1,329,131 | 1,266,902 | **−62,229** |
| Rust, launcher | 114,508 | 0 | **−114,508** |
| Rust, total (with `third_party/`) | 1,618,600 | 1,441,637 | −176,963 |
| Python (dev tooling) | 158,163 | 78 | −158,085 |
| Java (resource-prepare exporters) | 52,657 | 51,267 | −1,390 |
| Markdown | 40,027 | 12,196 | −27,831 |
| Workspace crates | 41 | 30 | −11 |
| Crates in `horizon-client`'s normal graph | 280 | 255 | −25 |
| Working tree (no `.git`, no `target/`) | 139 MB | 76 MB | −63 MB |

The Rust game is still 1.27M lines. **"Lite" here means fewer product surfaces and a smaller,
cleaner build graph — not a smaller Minecraft.** 1.07M of those lines are the game itself: world
generation, mob AI, redstone, the save format, the renderer. Anyone promising an 80% smaller
Horizon is selling you a different game.

---

## 1. The one architectural fact that decides everything

> **Single player is a one-client LAN server.**

`game/integrated.rs` starts a second `Game` (`serving`) on a "Server thread". The window joins it
through `lan::Lan::connect_local()` → an in-memory `horizon_protocol::connection::Pipe` → a real
login handshake on a `horizon-local-conn` thread. The window's `Game` has `remote: Some(..)` and
therefore runs `tick_remote()`, never `tick_world()`. Breaking a block is a `Serverbound*` packet;
the block change comes back as a `Clientbound*` packet.

Consequences, measured:

- `game/remote.rs` (13.4k), `game/lan_actions.rs` (6.9k), `game/lan*.rs` (≈4.5k),
  `game/integrated.rs` (1.4k), `game/levels.rs` (0.9k), `src/lan/` (37.7k) and
  `horizon-protocol` are **the game loop**, not multiplayer features.
- There are 238 `self.remote.is_some()` branches and 80 `self.serving` branches inside gameplay.
- `lan_screen.rs` (the UI) is the only piece of LAN that is safe to delete.

So "Lite is single-player only" cannot mean "delete networking". It means: delete the **external**
surfaces (server browser entry points we do not need, Realms, friends, dedicated server, relay)
while keeping the in-process packet loop. Deleting the loop is a 250–400 hour re-port of single
player back to in-frame ticking, with the in-tree test harnesses (11.4k LOC) assuming the server
thread. See [`reports/game.md` §3.3](reports/game.md) and [`reports/net.md`](reports/net.md).

That single finding reorders the whole plan: the highest-value cuts are *around* the hub, not
through it.

---

## 2. What v0.1 removed

### 2.1 Whole crates and trees

| Removed | Rust LOC | Why |
|---|---:|---|
| `launcher/` | 114,508 | GPUI launcher; hard-codes upstream release endpoints and upstream signing keys. A source-only fork must not ship an updater that installs someone else's binaries. `horizon-prepare` + `horizon-client` are a complete launcher-free path. |
| `crates/horizon-server` | 19,769 | Dedicated-server supervisor. Out of scope for a single-player fork. |
| `crates/horizon-port-pack` | 15,899 | Java modpack porting. |
| `crates/horizon-telemetry-server` | 5,834 | Ingest server for opt-in telemetry. |
| `crates/horizon-mod-registry` | 3,602 | Hosted mod index. |
| `crates/horizon-relay` | 2,377 | Play-with-Friends relay. |
| `crates/horizon-polytone` | 1,817 | **Dead crate**: a workspace member with zero consumers anywhere. |
| `crates/horizon-bots` | 1,784 | Server load-test bots. |
| `crates/horizon-release-sign` | 1,582 | Signed release checksums and upstream trust roots. |
| `crates/cargo-horizon-mod` | 840 | Mod-authoring CLI. |
| `crates/horizon-mod-deps` | 2 | Empty crate whose only job is to keep mod-only dependencies in `Cargo.lock`. |
| `packaging/` (except `icons/`) | — | Release folders for mac/linux/server installers. `packaging/icons/horizon.ico` is a Windows build input and stays. |
| `xtask` `package-server` path | — | No server to package. `xtask` stays for `package`/`tokens`/`mod-api`. |
| `benchmarks/`, `roadmap/`, `ROADMAP.md` | — | 17 MB of historical results and upstream release/marketing state. |
| `tools/` (1,101 files) | 144,690 py | Kept only `tools/native-hook-fragments/` (a **hard build input** for the mod-API codegen) and `tools/check_public_tree.py` (the anti-Mojang-files git hook). The 569 parity harnesses need the real 26.3 jars and a Mac mini; they do not transfer to a public fork. |
| `tests/` (Python infra) | 13,441 py | Kept `tests/fixtures/` only: three fixtures are `include_str!`-ed by the client's test target. |
| `docs/` (207 files) | 27,831 md | Kept the technical references that still describe kept code; dropped launcher, server, telemetry, mod/parity/release docs and 8.6 MB of upstream media. |
| `mods/horizon/src/{bench,neoforge-bench,neoforge-oracle}` | 1,390 java | Dev benchmarks. `mods/horizon/src/test/java/` **stays**: it is the resource preparer's source, compiled by `horizon-prepare` on first run. |

### 2.2 Game-level cuts

| Removed | LOC | Notes |
|---|---:|---|
| Realms (`realms.rs` + `realms/`) | 8,609 | Microsoft's paid service: needs an account, a subscription and upstream's HTTP endpoints. The title button, its mode, its polling and its server-pack hand-off are gone. The menu compacts (Options/Quit move up one row). |
| `horizon-extras`, `controllers` defaults | — | The default build is now `["audio"]`. No cosmetics entry points, no emote wheel, no Discord, no Play with Friends, no heartbeat, no official/partner server injection, no Horizon Settings page, no controller code paths. The code still exists behind features; see §5 for why we did not delete it yet. |

The build is verified with `cargo check --workspace --all-targets` and
`cargo check -p horizon-client --no-default-features` (see [`STATUS.md`](STATUS.md)).

### 2.3 What we deliberately did **not** cut in v0.1

| Kept | Why |
|---|---|
| The LAN hub, `remote.rs`, `integrated.rs`, `horizon-protocol` | They are single player. See §1. |
| Resource packs, data packs, OptiFine CEM | Vanilla-adjacent, heavily threaded through the resource path; cutting them is a GATE project, not a delete (§5.2). |
| Content mods, shader packs | Big (11.6k and 29.6k) but their packages interpose on `build.rs`, the startup path and `gfx.rs`. Wrong first move for a fork that must stay patchable against upstream. |
| Multiplayer server list | The `Disconnected` screen and manual address join share the same code as single-player failure paths; removing the UI is a `title.rs` + `remote.rs` surgery for 3k LOC. Scheduled for v0.2. |
| Advancements, stats, scoreboard, redstone, all dimensions | Vanilla behaviour. Cutting them is redefining the game, not lite-ing the build. |
| Crash reports, logging, agent control | Diagnostics are how a fork survives; `horizon-ctl` is the only headless test path. |

---

## 3. Three coherent products, not one

From [`reports/product.md`](reports/product.md), the tiers we considered:

| | **A — Airgap** | **B — Local (chosen)** | **C — Sim** |
|---|---|---|---|
| Pitch | Vanilla single-player, zero sockets, zero accounts | Single-player-first, Open to LAN when you want it, still offline and account-free | Headless simulation core for embedding |
| Network | None (requires the in-frame re-port) | In-process hub + optional LAN, no internet services | None needed |
| LOC removed | ≈298k | ≈285k | ≈1.146M |
| Est. binary | ≤52 MB | ≤56 MB | 8–12 MB |
| Risk | HIGH (250–400 h re-port) | LOW–MED (incremental deletion) | HIGH (new API surface) |

**We ship Tier B as v0.1.** It is the smallest *honest* delta: no account, no internet service, no
telemetry, no launcher, no mod ecosystem — but vanilla saves, all three dimensions, mobs, redstone
and LAN still work because they are the game, not the product surface. Tier A becomes a build
profile (`--no-network`) once the in-frame port is funded. Tier C is parked.

---

## 4. What is still cuttable, ranked

LOC and risk from the audits. "Hours" is a clean removal with compile fixes and a test pass, not
a rewrite. The first block is the recommended v0.2.

### v0.2 — low risk, ~40 h

| # | Cut | LOC | Risk | Notes |
|---|---|---:|---|---|
| 1 | Agent/dev tooling + dev harnesses (`agent.rs`, `control.rs`, `repro.rs`, `*_fixture.rs`, `input_trace.rs`, `net_harness.rs`, `tick_script.rs`) | 9,188 | LOW | `agent.rs` has zero call sites; `--control` is opt-in. `dispense_fixture`/`input_trace` are interposed on gameplay — gate them behind a `dev-harness` feature, do not delete blindly. |
| 2 | Multiplayer-only UI (dialogs, code of conduct, links, social, friends screens, server-list entry points) | 5,292 | LOW | Inert in single player, but touches the `Screen` enum (~840 refs) — one variant per commit. |
| 3 | Dedicated-server code left in the game (`game/dedicated*`) | 5,088 | LOW | No gameplay call sites; `horizon-server` is already gone. Keep `horizon-server-files`: `control`, `tempban`, `chat_filter` and `profiles` use it. |
| 4 | Horizon extras UI + cosmetics + emotes + Studio | 4,413 + 6,343 | LOW | `horizon-extras` has exactly 4 gates, so this is a delete, not a flag flip. Cosmetics touch mob rendering in 13 files. |
| 5 | Shader pack loading (keep vanilla post effects) | 1,360 + 29,649 | LOW–MED | `horizon-shaders` + `horizon-shader-api` + `gfx/pack_*` + `shader_pack_list`. Keep `post_chain.rs`/`post_glsl.rs`: they draw vanilla's spider/creeper/underwater effects and use `naga` directly. |
| 6 | Tutorial, GameTest/master blocks, debug-world | ~6,400 | LOW | `tick_game_tests()` runs unconditionally in the shipping tick; gate it with the blocks. |

### v0.3 — medium risk, ~90 h

| # | Cut | LOC | Risk | Notes |
|---|---|---:|---|---|
| 7 | Native mod API | 37,541 + 9,900 | MED | The big one. `build.rs` `syn`-parses all 466 `game/` files on every build and emits 11k lines from `native-hooks.json`; 432 dispatch bodies; `use_hand` can be cancelled by a hook. Is also the largest build-time lever in the tree. Do it as its own release. |
| 8 | Commands + datapack functions + command blocks | 22,022 + 11,900 | MED | `/` handling, signs, command blocks and `lan/commands.rs` all share the registry. Cutting commands is redefining the game; only do it if "no cheats, no functions" is the product. |
| 9 | Advancements + stats + scoreboard | 6,574 | MED | 134+66+52 call sites. `persist.rs` reads the scoreboard for team membership: a blind cut silently reloads entities without teams. |
| 10 | Controllers + splitscreen | 10,541 | LOW–MED | Already off by default; deleting the source needs ~90 call sites and a 300–500 LOC startup rewrite (splitscreen owns `App::Ready`). |

### v0.4 — high risk, high effort

| # | Cut | LOC | Risk | Notes |
|---|---|---:|---|---|
| 11 | In-frame single player (Tier A) | ≈37,000 + `protocol` play stack | HIGH | Deletes `remote.rs`, `lan*.rs`, `integrated.rs`, most of `src/lan/`. 250–400 h. The old path is gone; test harnesses assume the server thread. This is the only change that makes "no networking" literally true. |
| 12 | Other dimensions (Nether/End) | ≈2,700 code, large behaviour | HIGH | `levels.rs` parks 48 fields per dimension and imports dragon/raids/sculk/machines/vehicles. Portals, respawn and dimension travel all change. |
| 13 | Redstone | 1,800 | MED | Cheap in LOC, ~100 call sites. Not a good trade: doors, lamps, hoppers and pistons are visible vanilla behaviour. |
| 14 | DataFixer | 21,365 | MED | Keep `datafix::files` + `datafix::dynamic` (~1,200 lines: every current-world load uses them). Cut only the 259 old versions, and only if "26.3 saves only" is acceptable. |
| 15 | Structures / worldgen features | 22,375 / 11,910 | MED | `without_structures` already exists as a flag; deleting the code needs client edits (`Chunk` stores `StructureStart`, `save.rs` persists it). Saplings and bone meal use `worldgen::live::LiveFeatures`, so killing the feature graph stops trees growing unless the lite generator grows them itself. |

### Not worth cutting

- **Per-mob files** (all <700 LOC, deep vanilla behaviour) and **per-block behaviour** (beacon,
  loom, cartography, composter, cauldron, jukebox, campfire — 3–4k total).
- **The renderer optimizations** (`gfx/cull.rs`, `voxel_occlusion`, GPU skinning). They are
  pixel-identical, on by default, and a real FPS win. F3 counts change if you delete them.
- **HDR** (330 lines) — its emission bits are baked into the mesher and read by `terrain.wgsl`;
  removing it touches the byte-for-byte section-mesh parity gate.

---

## 5. Traps

### 5.1 `horizon-extras` is not a lite switch

Despite the docs, the feature has **four sites**, all `cfg!`; there are zero
`#[cfg(feature = "horizon-extras")]` attributes. Turning it off compiles every cosmetics, extras,
PvP, Studio and agent file anyway. It hides two buttons and links 15 fewer crates. Removing those
subsystems is a deletion (or a proper gate) project — hence the v0.2 list above.

Same for `controllers`: the feature stubs `pad/hardware.rs` only; ~11.8k of pad code still
compiles. And `friends` is the one well-gated subsystem (`friends_off.rs` stub): use it as the
model for future gates.

### 5.2 Build inputs are scattered

- `tools/native-hook-fragments/` (160 JSON files) is read by `horizon-mod-api-gen/src/build.rs`;
  missing → every `horizon-client` build fails. **Do not `rm -rf tools`.**
- `native-hooks.json` (152 KB) and `crates/horizon-client/src/mod_api.rs` are parsed on every
  build. `mod_api.rs` is regenerated by `cargo run -p xtask -- mod-api`.
- `packaging/icons/horizon.ico` is embedded by the Windows build script and derives the 8 MB
  stack link argument (splitscreen needs it). We kept it.
- `mods/horizon/src/test/java/` (375 files) is not a test fixture: it is the Java source that
  `horizon-prepare` compiles with `javac --release 25` to generate the game's own resource tables.
  Without JDK 25 there is no first run. Made worse by deleting the releases' precompiled
  `exporters/` bundle: a source-only fork must build them locally.
- `tests/fixtures/*.json` are `include_str!`-ed by the client's test target. We kept those three.
- `horizon-client-render/build.rs` reads `horizon-client/src/game/native_hooks.rs`: a hidden
  source-level edge, so client and render build scripts must be removed together.

### 5.3 `[patch.crates-io]` is three real fixes

- `third_party/wgpu-hal`: Intel HD 520/530/UHD 620/630 descriptor-pool crash, macOS HDR
  CoreGraphics crash, Windows Vulkan VSync-off frame stalls. Keep.
- `third_party/libmimalloc-sys`: mimalloc v3 uses POPCNT on MSVC → dies before `main` on
  pre-Nehalem CPUs. Keep.
- `third_party/naga`: GLSL-frontend fixes for shader packs only. This is the one to drop **with**
  the shader-pack cut (§4 #5), together with the `[patch]` line and a `Cargo.lock` re-resolve.

### 5.4 Parity is gone, and that is a real loss

The upstream project checks itself against the real 26.3 jars with 569 differential harnesses.
Those need the jars, a JDK, and untold CPU time; they cannot run in a public fork's CI. By
deleting them we freeze the port at `4e6920a`: **we can no longer prove that a change matches
vanilla.** Keep that sentence in mind for every gameplay-touching commit. The audit reports and
`docs/` are the map; the harnesses are the compass we gave up.

### 5.5 Packaging and release

No signing key, no self-update, no release train, no Windows/macOS notarisation, no curseforge
key. `xtask package` builds a playable folder; tags are pushed by hand. Do not add an updater
that points at upstream: it would replace this fork with the official signed build.

---

## 6. The commit plan

The audit in [`reports/features.md` §8](reports/features.md) gives 14 green commits. State:

| | Commit | Status |
|---|---|---|
| C1 | Drop crates no game target uses | **done** (plus launcher, tools and docs) |
| C2 | System allocator | not done — 2k, optional |
| C3 | Drop the dedicated server | partial: `horizon-server` crate gone; in-game `game/dedicated*` remains |
| C4 | Drop telemetry, heartbeat and benchmarks | not done — `horizon_telemetry::system` is reused by crash reports; move it first |
| C5 | Drop Play with Friends | not done — 21 cfg sites, one clean stub to extend |
| C6 | Drop cosmetics, emotes, emote wheel | not done — v0.2 #4 |
| C7 | Drop Horizon Settings and extras UI | not done — partial: default build hides them |
| C8 | Drop PvP HUD, minimap, Studio, agent control | not done — v0.2 #1/#4 |
| C9 | Drop content mods and the registry | not done — v0.3 #7 |
| C10 | Drop Realms | **done** |
| C11 | Drop shader packs | not done — v0.2 #5 |
| C12 | Drop the native mod API | not done — v0.3 #7, highest risk |
| C13 | Trim renderer backends/build deps | not done — target-specific |
| C14 | Trim workspace, CI and probes | **done** (probes, tools, tests, CI) |

Each remaining step is a self-contained commit with `cargo check --workspace --all-targets` as the
gate. Follow the dependency order: edit consumers first, then delete the provider crate.

---

## 7. Decision log

1. **Fresh repo, not a GitHub fork.** No upstream PRs, ever. A GitHub fork would keep the "open a
   pull request" affordance and the fork network; a fresh snapshot with one import commit states
   the relationship plainly. MIT and `THIRD_PARTY_NOTICES.md` are preserved; the README says
   "unofficial fork" before it says anything else.
2. **Tier B, not Tier A.** "Single player only" is a product decision that costs a 250–400 hour
   re-port of the game loop. Shipping Tier B now and Tier A later is the only honest ordering.
3. **Delete crates, gate features.** Cargo features are additive; a `lite` feature that turns
   everything off becomes a 2×N test matrix and unbuildable combinations. Deletion is cheaper to
   maintain in a fork. A `lite` marker feature may exist for CI naming, but nothing should `cfg`
   on it.
4. **No launcher.** The documented `horizon-prepare` → `horizon-client --resources` path needs no
   account and no schema changes. `play.sh` wraps it.
5. **Keep the parity-era docs that describe code we kept**, delete the ones that describe removed
   product surfaces. A doc that lies is worse than no doc.
6. **Freeze the fork at `4e6920a` for v0.1**, then sync upstream manually per subsystem. Do not
   pretend this is a tracking fork.

---

## 8. Reference: the audits

| Report | Scope | Headline |
|---|---|---|
| [`reports/game.md`](reports/game.md) | `game.rs` + `game/` (324k) | 49% core, 29% cuttable; single player is a LAN server; 37k transport tax |
| [`reports/render.md`](reports/render.md) | renderer + graphics (223k) | Nothing graphical is behind a feature; ≈117k removable; HDR bits are in the mesher |
| [`reports/world.md`](reports/world.md) | `horizon-world` (193k) | 10.6k actually makes terrain; datafix is 21.4k; redstone is cheap to keep |
| [`reports/net.md`](reports/net.md) | protocol, LAN, servers | Keep the hub; ≈82k of external network surfaces is removable |
| [`reports/assets.md`](reports/assets.md) | assets, packs, mods, shaders | ≈157k deletable; the mod API is a build-script tar pit |
| [`reports/ui.md`](reports/ui.md) | UI, input, audio, cosmetics | `horizon-extras` is 4 gates; minimum playable UI ≈24–26k |
| [`reports/features.md`](reports/features.md) | cargo features, cut mechanics | 108 feature sites; deletion order C1–C14 |
| [`reports/infra.md`](reports/infra.md) | launcher, tools, tests, CI | Launcher unnecessary; `tools/native-hook-fragments` is a build input |
| [`reports/product.md`](reports/product.md) | tiers, invariants, branding | Tier B; MIT/attribution; no upstream endpoints or keys |
