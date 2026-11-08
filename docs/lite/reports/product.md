# Horizon Lite — product definition (v0.1 proposal)

**Base:** `horizon-rust/horizon` @ `4e6920a3` (2026-11-08), Minecraft: Java Edition 26.3, protocol 777.
**Target repo:** `Solenopsisbot/horizon-lite` — a new repository, not a GitHub fork-network entry, never PR'd upstream.
**Status:** product spec. No code changed yet.

> **TL;DR — ship Tier B ("Local") as Horizon Lite v0.1.** Single-player + LAN + resource packs; no internet, accounts, telemetry, launcher, mods, shaders or dedicated server. About 285k of 1.44M Rust LOC removed (~20%), a ≤56 MB binary, the same vanilla worlds and the same worldgen. It is the smallest responsible delta from upstream, and it does not require rewriting the single-player networking path. Tier A ("Solo"/Airgap) becomes a build profile after v0.1; Tier C ("Sim") stays parked.

---

## 0. Five facts about the base repo that constrain the product

These are not opinions. They decide what can be removed cheaply and what cannot.

**1. Single player is already a client of an in-memory server.**
`crates/horizon-client/src/game/integrated.rs` says every single-player world runs on a "Server thread", and "the window joins it as a player through memory". The join uses `horizon_protocol::connection::Pipe` — the same packet format as LAN and a dedicated server. `AGENTS.md` states it plainly: "Single player, LAN guests and dedicated servers all run the server code". Consequence: `horizon-protocol`, the LAN hub, and the remote-client packet path are **not** multiplayer-only code. Tier A cannot delete them; it can only delete the socket layer and the outbound client. Any plan that says "remove networking" and expects a large LOC cut is wrong.

**2. `horizon-extras` is not a lite switch.**
`docs/forking.md` says the feature covers cosmetics/emotes, the official/partner server list, Horizon Settings and Mods pages, Discord, Play with Friends, and the heartbeat. Its own "Not behind the feature" section lists the launcher, the mod runtime, agent control (`--control`, `horizon-ctl`), controllers, HDR, shader packs, and the graphics extras. Consequence: `--no-default-features` produces neither a lite product nor a tested one.

**3. The default build is the only one upstream tests.**
`docs/forking.md`: "Best effort: CI builds and tests the default only... nobody plays it as a client before a release." Consequence: the exact configuration we ship is a fork-only configuration, and we own its CI, smoke test, and release engineering. There is no upstream safety net for it.

**4. The project ships no Minecraft code or assets.**
`README.md`: "Horizon contains no Minecraft code or assets: an existing install... is reused". `CONTRIBUTING.md`: "No game files in the repo. Never commit game files, decompiled source or prepared resources (`.local/`)". `docs/how-horizon-is-built.md` admits one exception: the pre-1.13 block/item ID conversion tables in `crates/horizon-world/src/datafix/` are "taken from vanilla's code" because compatibility needs them. Consequence: we can ship a game that needs the user's own copy; we cannot ship prepared resources, textures, sounds, or a jar.

**5. Upstream moves fast and ships nightlies only.**
`docs/versioning.md`: "Since 2026-10-28 the game ships only Nightlies". Consequence: we pin a tested commit and sync deliberately; we never track `main` hour to hour, and we never let an upstream nightly define our release.

Two more numbers that shape expectations:

| Fact | Value | Source |
|---|---|---|
| Rust LOC, whole repo | 1,443,865 | counted over `crates/` + `launcher/` (`.rs`, 2,612 files) |
| Rust LOC, game workspace only | 1,329,357 | excludes `launcher/` (114,508) |
| Headless server binary | 46.8 MB + 589 MB prepared resources | `docs/server.md` (measured) |
| Cold dev build | 99.9 s Linux / 106.6 s Windows, 16 threads | `docs/build-times.md` |
| Harnesses upstream | 326 (2026-10-25); count drifts | `docs/how-horizon-is-built.md` |
| Player-visible parity gaps | 0 open of 833 found; "100% means 100% of what the harnesses compare" | `README.md` |

---

## 1. The three tiers

### Tier A — **Solo** (codename "Airgap")

> **Pitch:** *Vanilla 26.3 single-player in Rust, with the network, the launcher, the mods and the telemetry taken out.*

**Targets**

| Metric | Target | Note |
|---|---|---|
| Rust LOC remaining | ~1.146M | ~298k removed (20.6%) |
| Release binary | ≤ 52 MB | baseline client est. 55–65 MB; measure in week 1 |
| Time to title | ≤ 3.2 s | upstream measured 2.9–3.2 s on M4 Pro |
| Time to first block, existing world | ≤ 6.0 s | process start → break accepted, RD 16, 1280×720 |
| Time to first block, new world | ≤ 15 s | seed 1234, default worldgen, spawn chunks |
| Network syscalls | **zero** `AF_INET`/`AF_INET6` | `strace -f -e trace=network`, 60 s session |
| One-time first-run preparation | ≤ 5 min | from the user's own 26.3 install; JDK 25 required once |

**What it keeps**

- Survival, creative, hardcore and spectator; the vanilla rules exactly.
- **All three dimensions: Overworld, Nether, End.** This is deliberate. Dimensions are levels in the same server, not a bolt-on; the End/Nether are entangled with items, portals, mobs, advancements, music and progression. Removing them would break vanilla saves, worldgen parity and the product promise for <1% LOC. Keep them.
- Vanilla world generation, structures, biomes, features, caves, aquifers — same seed, same terrain.
- Mobs, villagers and trading, raids, redstone, fluids, block ticking, entities, projectiles, vehicles.
- The full vanilla command tree, scoreboard, advancements, recipe book, HUD, chat (local), subtitles.
- Vanilla save compatibility in both directions: `level.dat`, region files, playerdata, entities; worlds from 1.8 to 26.2 upgrade as vanilla's DataFixers do.
- Data packs (vanilla feature, not a mod platform).
- Controllers and narrator (both vanilla/accessibility; removing them would be a regression, not a lite feature).
- Audio (vanilla parity; a "no sound" build is a separate flag, not this tier).
- One `horizon-lite` binary, a `horizon-lite-prepare` helper, no launcher, no auto-update.

**What it removes**

- The launcher (`launcher/`, 114,508 LOC) and all its install/update/sign-in/telemetry-consent machinery.
- Dedicated server (`horizon-server`, `horizon-server-files`, `horizon-anticheat`, `horizon-chat-filter`, `game/dedicated*`).
- Outbound network: server list, direct connect, online-mode auth (`ureq`), Realms, friends/relay, heartbeat, telemetry.
- LAN: the TCP listener, connection handshake, I/O pool, discovery, Open-to-LAN UI. **Keep the in-memory hub and protocol** — single player needs them.
- Mods: `.hmod`, `.hnmod`, registry, modpacks, `horizon-mods`, `cargo-horizon-mod`, `horizon-port-pack`, `horizon-mod-registry`, `horizon-mod-api-gen`, `horizon-mcp`.
- Shader packs: `horizon-shaders`, `horizon-shader-api`, shader UI and options.
- Resource packs: `horizon-optifine`, `horizon-polytone`, pack loading/selection UI. Default assets only, "vanilla look".
- Cosmetics/emotes, the official server list, Play with Friends, Discord presence.
- Agent control (`horizon-ctl`, MCP, control socket).
- Horizon-only visuals: HDR, 1,024-chunk distant terrain, splitscreen, fullbright, dynamic lights, minimap, FPS/keystroke overlays, Replay Studio.
- Upstream release signing, bots, benchmark upload, telemetry server and client.

**Why this is still "Horizon" and not a different game:** every retained subsystem is the vanilla one. Lite removes *surfaces*, not *content* or *rules*. The 20% LOC cut is mostly launcher, tooling, mod/shader/pack formats and server infrastructure; the game core is ~1.1M LOC and stays.

---

### Tier B — **Local** (recommended v0.1)

> **Pitch:** *Single-player and LAN, resource packs, no internet: the private edition of Horizon.*

**Targets**

| Metric | Target | Note |
|---|---|---|
| Rust LOC remaining | ~1.159M | ~285k removed (19.7%) |
| Release binary | ≤ 56 MB | adds pack/optifine code back |
| Time to title / first block | same as A | core path unchanged |
| Network | no `AF_INET` until "Open to LAN"; then LAN broadcast/listen/accept only, **no outbound to a non-local address** | testable |
| First-run preparation | ≤ 5 min | same as A |

**What it adds over A**

- **Open to LAN**: vanilla-style local multiplayer, offline mode, up to 8 players, vanilla clients can join. No account, no internet, no NAT traversal, no UPnP, no STUN, no relay, no invite codes. It is the same trust model as vanilla's "Open to LAN": anyone on your network can join; only use it on a network you trust.
- **Resource packs**: vanilla `.zip` packs (`assets/`, `pack.mcmeta`), plus OptiFine-format CEM/random-entity textures/connected textures through `horizon-optifine`. No shader packs, no Polytone (1.8k LOC; can ship in 0.2 if asked).
- Data packs (already in A).

**What it still removes**

Everything in A except the LAN socket path and resource-pack loader: launcher, server, internet multiplayer, server list, online auth, friends/relay, telemetry, mods, shaders, cosmetics, agent control, HDR/distant terrain/splitscreen, auto-update.

**Why LAN is not "multiplayer" in the scary sense:** it is a TCP listener on the local network, vanilla protocol 777, offline UUIDs, no Mojang services, no telemetry, no outbound connections. It costs roughly 4k LOC because the hub already exists for single player. The product promise stays: *the internet is not involved*.

---

### Tier C — **Sim** (working name; parked)

> **Pitch:** *Horizon's vanilla world engine without the game: headless worldgen, simulation and saves for embedding.*

**Targets**

| Metric | Target | Note |
|---|---|---|
| Rust LOC remaining | ~298k | ~1.146M removed (79.4%) |
| Library + CLI | 8–12 MB | no wgpu, winit, cpal, gilrs |
| First simulated tick | ≤ 0.5 s | from a prepared save |
| Time to first block | N/A | no client; "first block" is `set_block` |
| Platforms | Linux x86-64 first | no GPU requirement |

**What it keeps**

`horizon-core` (23k), `horizon-world` (193k), `horizon-client-core` (9k), `horizon-items` (10k), `horizon-command` (12k), and `horizon-protocol` only because `horizon-command` depends on it. New façade crate `horizon-lite-sim` (~2–4k) exposing:

```rust
Sim::open(path) -> Result<Sim>          // vanilla save, 1.8–26.3
sim.tick(n)                             // 20 TPS semantics, same RNG order
sim.get_block(x, y, z) / set_block(...)
sim.generate_chunk(seed, cx, cz, dim)   // vanilla worldgen, all dimensions
sim.save(path)                          // vanilla-readable save
```

Block ticking/redstone/fluids from `horizon-world/src/level` are in scope; mob AI, rendering, audio, input, UI, network and mods are not. No API stability promise until a real embedder exists.

**Why parked**

- No identified embedder, no user, no distribution story.
- It forces an API design over `horizon-world` that upstream has no reason to keep stable; every sync becomes an API compatibility negotiation.
- The name collides with upstream's `horizon-engine` (the no-default-features server build, `docs/server.md`). Use `horizon-lite-sim` if it ever ships.
- Keep the door open cheaply: do not add client/render dependencies to `horizon-core`/`horizon-world` in Lite. That is a one-line rule, not a project.

**Trigger to build it:** a real embedder (a server host, a map tool, an AI training environment) commits to using it, or we need it ourselves for testing. Then do a 90-day spike with the save/tick acceptance test above; do not put it on the v0.1 critical path.

---

### Tier comparison

| | **A — Solo (Airgap)** | **B — Local (v0.1)** | **C — Sim** |
|---|---|---|---|
| Single-player, all 3 dimensions | ✅ | ✅ | ✅ (no client) |
| Vanilla saves both ways | ✅ | ✅ | ✅ |
| Vanilla worldgen / mobs / redstone / commands | ✅ | ✅ | worldgen + block simulation; no mob AI/commands |
| LAN | ❌ | ✅ (offline, 8 players) | ❌ |
| Internet multiplayer / server list / accounts | ❌ | ❌ | ❌ |
| Dedicated server | ❌ | ❌ | ❌ |
| Resource packs | ❌ | ✅ (vanilla + OptiFine CEM) | ❌ |
| Data packs | ✅ | ✅ | ✅ |
| Mods (`.hmod` / `.hnmod`) | ❌ | ❌ | ❌ |
| Shader packs | ❌ | ❌ | ❌ |
| Telemetry / heartbeat / crash upload | ❌ | ❌ | ❌ |
| Launcher / auto-update | ❌ | ❌ | ❌ |
| Controllers + narrator | ✅ | ✅ | ❌ |
| Agent control / MCP | ❌ | ❌ | ❌ |
| HDR / distant terrain / splitscreen | ❌ | ❌ | ❌ |
| Network sockets | none | LAN only, opt-in | none |
| Rust LOC left | ~1.146M | ~1.159M | ~298k |
| Binary / artifact | ≤52 MB | ≤56 MB | 8–12 MB |

---

## 2. Recommendation: Tier B is Horizon Lite v0.1

**Ship B.** Five reasons, in order of weight:

1. **It is the smallest honest delta from upstream.** A has to remove the LAN listener and UI while preserving the in-memory hub that single player uses. That is delicate surgery on the most coupled subsystem in the game, and every upstream change to `lan/` becomes a conflict. B keeps the path upstream already tests (LAN + integrated server) and removes only what is clearly separable: launcher, server, auth, telemetry, mods, shaders, internet client.
2. **It does not amputate a vanilla feature to look small.** Resource packs are vanilla content. LAN is vanilla's own "Open to LAN". Removing both makes the build feel like a demo and invites "why can't I...?" support load. B's promise is already strong without that.
3. **The privacy story is intact.** No internet, no account, no telemetry, no outbound connections. LAN is opt-in, local and uses vanilla's offline trust model. A's extra guarantee (zero sockets) is better delivered as a build profile once B ships, not as a v0.1 rewrite.
4. **Maintenance is the scarce resource.** The ~285k-LOC deletion touches ~30 upstream files and is mergeable monthly. A's socket surgery touches the same files upstream changes most (LAN, integrated server, remote client). A fork lives or dies on sync cost.
5. **A and C remain cheap options.** A is `--features airgap` plus the socket/listener removal; it can be a v0.2 release if users ask for an airgapped build. C is a future spike; keeping core crates free of client deps costs nothing now.

**If you want the sharpest possible story and can spend two extra weeks on the socket refactor, choose A.** My recommendation is B because v0.1 needs to ship, and B is the version that survives the second upstream sync.

### v0.1 scope (Tier B)

**In:** single-player; all three dimensions; vanilla worldgen/saves/mobs/redstone/commands; LAN (offline); resource packs; data packs; controllers/narrator; one binary + prepare; Linux x86-64 release (macOS Apple Silicon source-build best effort; Windows untested, no binary).

**Out:** launcher; dedicated server; internet multiplayer/server list/Realms; accounts/online mode; friends/relay; telemetry/heartbeat/crash upload; mods; shader packs; cosmetics/emotes; agent control/MCP; HDR; distant terrain; splitscreen; auto-update; OptiFine Polytone packs (0.2 candidate).

**Success definition:** a new user with Minecraft 26.3 installed can run `horizon-lite prepare`, then `horizon-lite`, create a world, break a block, save, quit, reopen it, and open the same save in vanilla 26.3 — with the process making no internet connection at any point unless they click "Open to LAN".

---

## 3. The invariant checklist

What must remain true for "Horizon Lite" to be an honest fork rather than a different game wearing the name. Each item has an enforcement mechanism, not just a promise.

| # | Invariant | Why it matters | Enforced by |
|---|---|---|---|
| 1 | **Vanilla saves work both ways.** Read `level.dat`, region `.mca`, playerdata, entities; worlds from 1.8 to 26.2 upgrade as vanilla's DataFixers do. A Lite save opens in vanilla 26.3; a vanilla 26.3 save opens in Lite. | This is the product. Without it, Lite is a Minecraft-like, not a replacement. | Upstream `save_roundtrip`, `world_reopen`, `datafix` harnesses; a manual vanilla-open check each release. `README.md` claims "saves round-trip with vanilla". |
| 2 | **Block, item and block-state IDs stay vanilla.** Same numeric IDs, state encoding, item components, registry order. | Saves, worldgen and commands all depend on it; changing IDs silently corrupts worlds. | `chunk_generation`, `save_roundtrip`, `item_model` harnesses; `horizon-items` / `horizon-core` tables untouched. Upstream: "paletted containers, identical to vanilla over 266 scenarios". |
| 3 | **Worldgen is vanilla for the same seed, in all three dimensions.** Terrain, structures, features, caves, aquifers, decoration order. | "Same seed, same world" is the central promise; a prettier generator is a different game. | `chunk_generation`, `worldgen`, `feature_placement`, `structure` harnesses; sample 100 chunks/dimension vs upstream before each release. |
| 4 | **Tick order and random draws match vanilla.** 20 TPS, mob AI, redstone, block updates, loot, explosions, command execution. | `CONTRIBUTING.md`: "vanilla is the specification, down to the order of random calls." Lite is not a gameplay remix. | Upstream harnesses for retained systems; no gameplay edits in the lite patch set without a harness. |
| 5 | **LAN speaks vanilla protocol 777, offline mode.** A vanilla 26.3 client can join a Lite LAN world, and vice versa. Verify this in v0.1; if it fails, narrow the claim to Lite clients rather than ship a false promise. | If we keep LAN, it must be vanilla LAN, not a proprietary co-op mode. | `lan_e2e`, `dedicated_server` protocol tests (LAN variant); manual vanilla-client join. |
| 6 | **No Minecraft code or assets in the repo, history or releases.** No jars, `.class`, `.java`, `.local/`, prepared resources, `horizon-data.bin`, screenshots containing Mojang textures. | The whole legal basis of the project. | `tools/check_public_tree.py` + `.githooks/pre-commit` and `pre-push`; keep the pre-push history audit. |
| 7 | **Resources are prepared from the user's own copy; prepare never downloads the game.** | `README.md`: "Horizon contains no Minecraft code or assets"; `docs/launcher-preparation.md`: exporters are original, jars stay local and are verified against `research-lock.json`. | `horizon-lite-prepare` code review + test that it refuses a missing jar and makes no network call; keep `research-lock.json`. |
| 8 | **MIT attribution survives.** Keep `LICENSE` with upstream's copyright; keep `THIRD_PARTY_NOTICES.md`; keep file-level notices; add ours for changes. | MIT requires the copyright and permission notice in copies; removing it is a license violation, not a "cleanup". | CI check that `LICENSE` contains "Ludovic Marie and the Horizon contributors"; `FORK.md` lists modifications. |
| 9 | **No official Horizon services, keys or endpoints.** No `playhorizon.dev` telemetry, cosmetics, friends, registry, update feed, release keys or signed artifacts. | The fork must not impersonate upstream or send its users' data to upstream. | `tools/check_lite_scope.py` greps code/config for `playhorizon.dev`, `telemetry.`, `horizon-rust` endpoints; no `ureq` in the default dependency graph. |
| 10 | **No telemetry, heartbeat or crash upload.** Not "off by default" — absent. | `docs/telemetry.md` has an always-on "I'm playing" ping and a cosmetics presence; both are unacceptable in Lite. | Code deleted; no-network integration test; grep for `heartbeat`, `telemetry`, `outbox`, `install_id`. |
| 11 | **Version pin is explicit: Minecraft 26.3, protocol 777.** No silent upgrade to 26.4; a newer save is refused with a clear message, not half-read. | A moving target breaks saves and parity claims. | `UPSTREAM.md` pins base commit + MC version; version check in `horizon-core`; release notes say the pin. |
| 12 | **The DataFixer tables are disclosed as vanilla-derived data.** Keep the exception in `docs/how-horizon-is-built.md`; do not expand it. | Honesty about the one place the repo admits vanilla code. | `docs/LICENSING.md` reproduces the disclosure; review any change to `crates/horizon-world/src/datafix/`. |
| 13 | **Branding is unambiguous: unofficial fork, not Horizon, not Mojang.** | Trademark and user trust. | README first block, window title, About screen, `--version`, crash reports; see §5. |
| 14 | **Removed features stay removed.** No mods/shaders/server/telemetry creep back in a "small PR". | Scope drift is how a lite fork becomes upstream with extra steps. | `tools/check_lite_scope.py` in CI; `docs/LITE-SCOPE.md` is the contract; a major-version decision to change it. |
| 15 | **Builds are reproducible from source.** `Cargo.lock` committed, toolchain pinned (`rust-toolchain.toml`, 1.95), no prebuilt binaries, no unverified downloads. | Users must be able to trust the binary they run. | CI builds from a clean checkout; release artifacts ship with SHA-256; no self-hosted secrets. |

### 3.1 What the repo itself says about assets and licensing

Use these quotes verbatim in `docs/LICENSING.md`; do not paraphrase them into something stronger.

- **MIT, original work only.** `README.md` §Licence: "MIT, for the project's original work; dependencies keep their own licences". `LICENSE` is the standard MIT text, "Copyright (c) 2026 Ludovic Marie and the Horizon contributors".
- **No Minecraft code or assets.** `README.md` §Download: "Horizon contains no Minecraft code or assets: an existing install... is reused". §Build from source: "Prepared files land in the gitignored `.local/`: never commit or share them."
- **The datafix exception.** `docs/how-horizon-is-built.md`: "Horizon contains no Minecraft code or assets... Horizon's code does hold some of the game's data that compatibility needs: the tables that convert the block and item ids of pre-1.13 worlds (`crates/horizon-world/src/datafix/`), taken from vanilla's code."
- **Exporter classes only.** `docs/launcher-preparation.md`: "These contain only Horizon's original Java exporter classes. Minecraft jars, libraries, assets and generated resources remain local and verified against `research-lock.json`."
- **Repo hygiene is enforced.** `CONTRIBUTING.md`: "No game files in the repo. Never commit game files, decompiled source or prepared resources (`.local/`)". `AGENTS.md`: "Never commit Mojang's files". `tools/check_public_tree.py` rejects `.local`, `decompiled`, `minecraft`, `assets`, `run`, `logs`, `.jar`, `.class`, `.java`, and `horizon-data.bin`.
- **Third-party code has rules.** `CONTRIBUTING.md` allows MIT/BSD/Apache/ISC/zlib/0BSD/Unlicense/CC0 and forbids GPL/LGPL/AGPL/MPL/Polyform/CC-BY/OptiFine/unlicensed code even to read. `THIRD_PARTY_NOTICES.md` records the three pieces once removed for license (Iris-derived shader code, OpenJDK-derived math, OpenJDK `HashMap`) and the current third-party notices. **Any sync must preserve this history and must not reintroduce those files.**
- **Trademark.** `README.md`: "NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT. Minecraft is a trademark of Mojang Synergies AB..." `packaging/PLAY.txt`: "Horizon is an unofficial fan project, not affiliated with, endorsed by or connected to Mojang Studios or Microsoft."

**What this means for us:** we can redistribute MIT code and our modifications; we cannot redistribute Mojang's code, assets, prepared resources, or screenshots that contain them. The fork's `LICENSE` must keep upstream's notice; the fork's README must keep the Mojang disclaimer; the fork must not use upstream's release keys or imply upstream endorsement.

---

## 4. The user-facing promise, non-goals, and what "lite" does not mean

### The promise (Tier B, v0.1)

> **Horizon Lite plays Minecraft: Java Edition 26.3 the way single-player should.** Your worlds, your rules, your terrain, in one native program with no Java at runtime, no account, no internet, no telemetry, no launcher, no mods and no shader packs. It opens vanilla saves and writes saves vanilla can open. Click **Open to LAN** when you want to play with someone in the same room; otherwise it never touches the network. You prepare it from the copy of Minecraft you already own — we ship none of Mojang's files and never download them for you.

The one-time preparation needs Java 25 and the 26.3 client/server files you already own. That is the only Java in the story; the game itself is Rust.

### Non-goals (v0.1 and, unless deliberately changed, forever)

- **Not a mobile, console or Steam Deck port.** Desktop Linux first; macOS/Windows source builds are best effort. No touch UI, no controller-first redesign (controllers work because vanilla has them).
- **Not a minigame, adventure map, or "Minecraft-like".** No new blocks, mobs, biomes, items, progression or gameplay rules. Vanilla is the spec.
- **Not a rewrite or a fork of the gameplay.** We trim surfaces; we do not reimplement worldgen, rendering, mob AI or physics.
- **Not a modding platform.** No `.hmod`, `.hnmod`, registry, modpacks or native hooks. Data packs and resource packs are vanilla content, not code.
- **Not a server.** No dedicated server, no hosting panel, no `server.toml`, no anticheat, no chat filter. LAN is the only multiplayer.
- **Not an online service.** No accounts, no server list, no Realms, no friends/relay, no telemetry, no crash upload, no update check.
- **Not a launcher.** One binary + one prepare helper; manual downloads and SHA-256, no self-update.
- **Not a performance modpack.** We inherit upstream's engine; we do not claim new FPS records. If we publish numbers, they are our own measurements with method.
- **Not a parity certification for removed features.** We claim parity for what ships, verified by the harnesses we actually run; we do not claim 100% of upstream's audit.
- **Not a way to play without owning Minecraft.** The prepare step needs your own copy; we do not bypass that.
- **Not a fork that follows every upstream nightly.** We pin, sync deliberately, and publish our base.

### What "lite" does NOT mean

- It does **not** mean fewer blocks, items, mobs, biomes or dimensions. All three dimensions and the full vanilla content stay.
- It does **not** mean simpler worldgen, flatter terrain, or "Minecraft but small". Same seed, same world.
- It does **not** mean a demo, a trial, or a cut-down creative mode. Survival is complete.
- It does **not** mean a different save format. Vanilla saves, both directions.
- It does **not** mean "Minecraft rewritten again". It is Horizon, trimmed.
- It does **not** mean "no Java ever". Java 25 is needed once, to prepare resources from your own copy; the game has no JVM.
- It does **not** mean "tiny binary". The renderer and worldgen are the product; expect roughly 10–15% smaller, not 80%.

---

## 5. Naming, branding, and licensing

### Name

**Primary: "Horizon Lite"**, always with **"(unofficial fork)"** in the same visual block at first mention, in the README title, the window title, the About screen, `--version`, crash reports, and release notes.

Why not something else:

- **"Horizon Solo"** is narrower than Tier B and reads like a mode.
- **"Horizon Plain"** is taken by upstream's `horizon-rust/horizon-plain`, which builds official tags without `horizon-extras`. We are not that. Say so explicitly in the README.
- **"HZ Lite"** is cryptic and hurts search.
- **"Lumen"** is clean but loses the fork lineage and the searchability of "Horizon".

**Fallback if upstream objects:** rename the product (keep the repo) to a neutral name such as **"Lumen"** and keep "a fork of Horizon" as the subtitle. Do not fight a trademark request; the code is MIT, the name is not.

### Identifiers (avoid collisions with an official Horizon install)

| Thing | Value |
|---|---|
| GitHub repo | `Solenopsisbot/horizon-lite` (new repo, not a GitHub fork) |
| Product | `Horizon Lite (unofficial fork)` |
| Game binary | `horizon-lite` |
| Prepare helper | `horizon-lite-prepare` |
| Package/crate (new thin bin) | `horizon-lite` (depends on `horizon-client` lib; keep upstream crate names) |
| App ID | `dev.solenopsisbot.horizon-lite` |
| Data folder | `horizon-lite` (not `horizon`) |
| Env vars | `HORIZON_LITE_HOME`, `HORIZON_LITE_GAME_DIR` (do not reuse `HORIZON_HOME`) |
| Version | independent semver, `0.1.0`; print `horizon-lite 0.1.0 (Horizon base 4e6920a3, Minecraft 26.3)` |
| Release tags | `v0.1.0`, `v0.1.1` — never `v0.2.x`, never `nightly-*` |
| Signing | GitHub artifact attestations / SHA-256; **no** upstream release key, no `horizon-release-sign` |

Using a separate data folder matters: it prevents Lite from reading an official install's telemetry consent, options, mods or saves by accident, and lets both coexist. Never write to `~/.local/share/horizon` or `~/.local/bin/horizon-*`.

### Visual identity and fork relationship

- **Do not reuse upstream's banner, logo, `docs/media` screenshots, or the Horizon wordmark.** The code is MIT; the brand and the Mojang-derived screenshots are not ours to ship. Make a plain text wordmark or a simple geometric icon in `lite/branding/` that we own.
- **First line of README:** "Horizon Lite is an independent, unofficial fork of [Horizon](https://github.com/horizon-rust/horizon), which is by Ludovic Marie and the Horizon contributors. It is not affiliated with, endorsed by, or supported by them."
- **`FORK.md`:** base commit, base date, what we changed, our copyright, how to report Lite bugs, and "do not report Lite bugs to upstream."
- **About screen / crash reports:** the same sentence, plus the Mojang disclaimer. A user should never be able to confuse a Lite crash with an upstream one.
- **Release notes:** "Lite v0.1.0, based on Horizon commit 4e6920a3. Changes since upstream: ..." Link upstream once, not in every paragraph.
- **Do not call it "official", "Horizon 2", "Horizon Next", "the real Horizon", or "Horizon without the bloat"** (the last implies upstream is bloated; it is not our fight).

### MIT obligations, concretely

1. **Keep upstream's MIT text and copyright line intact.** `LICENSE` contains "Copyright (c) 2026 Ludovic Marie and the Horizon contributors" and the MIT permission notice. Do not replace it with our name or delete it.
2. **Add our notice without overwriting theirs.** Put "Portions Copyright (c) 2026 Solenopsisbot and the Horizon Lite contributors" below the upstream line in `LICENSE`, or in `NOTICE`/`FORK.md`. MIT requires the original notice in copies; adding ours is fine.
3. **State the modifications.** `FORK.md` lists: removed launcher/server/network/mod/shader/telemetry surfaces; added Lite binary, prepare wrapper, scope fence, no-network tests; changed branding. Git history is the detailed record.
4. **Keep `THIRD_PARTY_NOTICES.md`.** If we delete a crate, its notice can stay (harmless) or move to an "removed in Lite" section. If we add a dependency, add its notice. Keep file-level copyright headers, especially `crates/horizon-client-render/src/fluid_render.rs` (Catnip/Ponder MIT) and the `third_party/` licenses.
5. **Do not relicense the combined work more restrictively.** MIT permits it, but it would violate the spirit and complicate upstream sync. Keep Lite MIT.
6. **Do not use upstream's release keys or signed checksums.** `crates/horizon-release-sign/release-keys.txt` is upstream's; delete the crate from Lite and do not sign as Horizon. Use GitHub attestations or publish SHA-256.
7. **Trademark is separate from copyright.** MIT does not grant rights to the "Horizon" name or logo. The "(unofficial fork)" tag and the disclaimer are not decoration; they are the license to use the name descriptively. No Mojang logos, no "Minecraft" in the product name, no official-looking branding.

---

## 6. Maintenance: sync from upstream, with a budget and a freeze fallback

### Recommendation

**Sync from upstream; do not fork-and-freeze.** Freezing at v0.1 inherits every save/worldgen/parity bug upstream fixes next month, and the core value of Lite is *vanilla correctness*. But sync on a budget, not continuously.

- **Base:** full upstream git history up to `4e6920a3`, pushed to a **new** GitHub repo (not the fork network). This preserves authorship/attribution and makes `git merge upstream/main` possible. A file copy with no history cannot sync.
- **Remote:** `origin` = `Solenopsisbot/horizon-lite`; `upstream` = `https://github.com/horizon-rust/horizon.git`, **fetch-only**. Set `git remote set-url --push upstream DISABLED` so no agent can push by accident.
- **Cadence:** monthly, plus immediately for a save-corruption/security fix. Sync to an upstream commit that has been on `main` ≥7 days and passed upstream CI; never to a fresh nightly. Pin the base in `UPSTREAM.md` (commit, date, MC version, harness count).
- **Merge, never rebase.** Create `sync/YYYY-MM-DD` from `main`, `git merge upstream/main`, resolve, run the checklist, merge to `main` with `--no-ff`, delete the branch. Never force-push `main`; it is public history.

### Repository structure

**Vendor the trimmed tree at the repo root.** Not a submodule, not a `lite/` subdirectory, not a long-lived `lite` branch.

- Cargo workspace paths, `tools/`, `.githooks`, `docs/` and CI all assume the root. Moving the game under `lite/` breaks every path and every upstream merge.
- A submodule would force building upstream unmodified, which is the opposite of the product.
- A long-lived `lite` branch doubles every merge and makes "what is main?" ambiguous. One `main`, short-lived sync branches, tags.
- Add:
  - `lite/` — our scripts, branding, packaging, CI helpers.
  - `docs/lite/` — `SCOPE.md`, `PARITY.md`, `SYNC.md`, `LICENSING.md`, `BRANDING.md`.
  - `UPSTREAM.md` — base commit/date/version, sync log.
  - `FORK.md` — fork relationship, modifications, bug-reporting.
  - `rust-toolchain.toml` — pin 1.95 (the workspace `rust-version`; README's "1.90+" is stale).
- Delete or replace: `launcher/`, server/mod/shader/telemetry/friends crates, `benchmarks/` (260 dirs), `roadmap/` + generated `ROADMAP.md`, `native-hooks.json`, `mods/` Java oracles for removed features, `docs/media/`, upstream `.github` workflows/templates, `.github/release-line.txt`, `CODEOWNERS`, `trusted-reviewers.txt`.

### Patch budget (the early-warning system)

After each sync, measure:

```sh
git diff --stat upstream/main...main | tail -1
git diff --numstat upstream/main...main | awk '{a+=$1; d+=$2} END {print a+d}'
```

- Target: **<5% of files** and **<2% of LOC** changed vs the upstream base.
- If >10%: stop, simplify the delta (prefer a `cfg`/feature over deletion, or drop a tier), then resume.
- A delta that grows every sync will eventually make the fork unmergeable. Treat the budget as a release gate, not a nice-to-have.

### CI

- GitHub-hosted runners only. **Delete** every upstream workflow that uses self-hosted runners, secrets, release keys, launcher builds, telemetry, mod registry, nightly, parity shards, claim/triage bots, or `pr_ready.py --base upstream/main`.
- Keep one `ci.yml`: `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test` for retained crates, `check_public_tree.py`, `check_lite_scope.py`, and the no-network unit/integration test where the runner allows it.
- **Parity harnesses cannot run in public CI** (they need the user's 26.3 jars). Keep them as local pre-release checks; `PARITY.md` records what was run, on what machine, at what commit. Never display a "100% parity" badge generated from a CI that did not run them.

### Sync checklist (put this in `docs/lite/SYNC.md`)

1. Fetch `upstream`; read the diff since the pinned base.
2. Check `LICENSE`, `THIRD_PARTY_NOTICES.md`, and `docs/how-horizon-is-built.md` for license changes or new third-party code.
3. Check for new network calls, telemetry, official endpoints, release keys, mod/shader/server features.
4. Merge into `sync/YYYY-MM-DD`; resolve conflicts preferring upstream in retained subsystems and our trim in deleted ones.
5. `cargo fmt`, `clippy`, `cargo test`; `check_public_tree`; `check_lite_scope`.
6. Run the local save/worldgen sample + no-network test.
7. Measure binary size and time-to-first-block; compare to targets.
8. Update `UPSTREAM.md` and `PARITY.md`.
9. Merge to `main`; tag `v0.1.x`; publish SHA-256 + release notes.
10. If any step fails, keep the old release; do not ship a half-synced tree.

### Freeze fallback

If there is no maintainer for six months, **publish a final release and archive the repo with the pinned base and a clear "unmaintained" notice**. Do not leave a repo that claims to sync but doesn't. Fork-and-freeze is a valid ending, not a valid default.

---

## 7. Risks and how to neutralize them

| # | Risk | Likelihood / impact | Mitigation |
|---|---|---|---|
| 1 | **Parity expectations.** Upstream claims 100% and 0 gaps; Lite removes features and cannot inherit the claim. Users file "missing feature" bugs or expect vanilla multiplayer. | High / High | Scope the claim in `README.md` and `PARITY.md`: "vanilla parity for the single-player scope, verified by the harnesses listed; not a claim about removed features." Issue template asks "Does it reproduce in vanilla 26.3?" and routes removed-feature reports to a closed "non-goal" answer. No 100% badge. |
| 2 | **Docs claim 100% parity.** `README` has badges and a full parity table; `docs/rust-parity.md` says parity *has not* been reached and targets Linux only; `ROADMAP.md` claims more. Inheriting all three is incoherent. | High / High | Delete `ROADMAP.md` + `roadmap/`; rewrite README; delete or archive `docs/rust-parity.md` with a banner; keep only `docs/parity-workflow.md` for devs. One claim, one date, one commit, one harness list. |
| 3 | **AGENTS.md / CONTRIBUTING.md assume upstream process.** The current `horizon-lite/AGENTS.md` is a verbatim 24 KB upstream copy: "Claim before you start", `/claim`, "small PRs", release labels, "Contributors first", Discord, `pr_ready.py --base upstream/main`, upstream CI runners. Agents will optimize for the wrong repo. | High / High | Replace both before any code work. New `AGENTS.md`: "STOP — this is a downstream fork. Never open PRs against horizon-rust, never push upstream, never add back removed features, no network/telemetry, no Mojang files." Keep the useful build/test/file-map sections. Archive the old file as `docs/upstream/AGENTS.md` with a banner if history matters. Rewrite `.claude/skills/vanilla-parity/SKILL.md` to drop upstream issue/PR workflow. |
| 4 | **Issue/PR templates and 21 workflows.** No issue templates upstream; the PR template demands `pr_ready.py`, labels and vanilla references; workflows reference secrets/self-hosted runners that do not exist in our repo. | High / Medium | Add Lite issue templates (bug, save-corruption, non-goal/feature-request auto-close, security). Replace the PR template with a short Lite one. Delete all workflows except `ci.yml`; add `lite.yml`. Remove `CODEOWNERS`, `release-line.txt`, `trusted-reviewers.txt`. |
| 5 | **Removed features creep back.** A well-meaning PR adds a mod loader, a server, or a telemetry "just for crash reports". | Medium / High | `docs/lite/SCOPE.md` is the contract; `tools/check_lite_scope.py` fails if removed crates/deps/endpoints reappear; CI required. Any change needs a major-version decision, not a drive-by PR. |
| 6 | **Network/telemetry regression.** A sync reintroduces `ureq`, the heartbeat, the official server list, or an update check; a "harmless" telemetry crate starts sending. | Medium / High | Delete the code, not just the feature flag. `check_lite_scope.py` greps for `playhorizon.dev`, `telemetry`, `heartbeat`, `outbox`, `install_id`, `ureq` in the default graph. `strace` no-AF_INET test in release checklist. Tier B test: no outbound before LAN. |
| 7 | **Mojang assets/license.** A contributor commits a texture, a prepared `.local` folder, a screenshot, or a jar "for tests"; or a sync reintroduces the removed GPL-derived files. | Medium / High | Keep `check_public_tree.py` + hooks; pre-push history audit; `FORK.md` license rules; sync checklist checks `THIRD_PARTY_NOTICES` and the "code removed for its license" list. No screenshots in the repo at v0.1. |
| 8 | **Upstream drift / license change.** Upstream moves to 26.4, changes `horizon-extras`, or changes license; a merge becomes a rewrite. | Medium / High | Pin 26.3 + a commit; sync only 26.3.x fixes; check `LICENSE` at every sync; if upstream changes license, stop syncing and keep the last MIT base. Patch budget catches drift early. |
| 9 | **Build prerequisites.** No launcher means the user must find Minecraft 26.3, a server jar, and JDK 25 to prepare resources; first-run failure is the top support issue. | High / Medium | `horizon-lite prepare` wizard: find `~/.minecraft`, check 26.3, explain the server jar path, run exporters with progress, clear errors, `--resources DIR` to reuse a prepared folder. Document "Java 25 once, never at runtime." Measure cold first-run ≤5 min. |
| 10 | **LAN security.** An unauthenticated LAN port is exposed on a café/hotel network; users assume it is private. | Medium / Medium | Keep vanilla's trust model but say it loudly: "Only on a network you trust"; bind to LAN/private interfaces by default; no UPnP/STUN/relay; no internet exposure; a one-click "Stop sharing"; log the port and interfaces. |
| 11 | **Binary size expectation.** "Lite" sounds like <10 MB; the renderer/worldgen make it ~50 MB. | Medium / Medium | State the number in the README up front: "~50–56 MB, because the game is the product; the cut is surfaces, not terrain." Do not market on size. |
| 12 | **CI cannot run parity.** Public runners have no Mojang jars; a regression in worldgen/saves ships unnoticed. | High / High | Keep a local pre-release harness subset + a 100-chunk/dimension worldgen sample + save round-trip + manual vanilla open. Publish `PARITY.md` with date/machine/commit. Never claim CI ran what it didn't. |
| 13 | **Trim breaks retained behavior.** Deleting `horizon-cosmetics`, `horizon-theme`, or pack code pulls a thread that changes rendering/menus/saves. | Medium / High | Trim in small commits; `cargo test` after each; keep a smoke save; don't delete `horizon-theme`/`horizon-assets` until imports are clean; prefer `cfg` over deletion where the dependency graph is tangled. |
| 14 | **Upstream support confusion.** Users ask upstream for help with Lite, or upstream maintainers get Lite bug reports. | Medium / Low | README, About, crash reports, and issue templates all say "Do not report Lite bugs upstream"; `FORK.md` has the Lite issue link; release notes repeat it once. |
| 15 | **Maintenance abandonment.** The fork syncs twice and dies; users are left on a stale 26.3 build with a "100% parity" claim. | Medium / Medium | Patch budget + monthly cadence; if it lapses, publish a final release and archive with the pinned base. No false "actively maintained" claims. |
| 16 | **Naming/trademark.** "Horizon Lite" implies official endorsement; upstream or users object. | Low / Medium | "(unofficial fork)" everywhere; no upstream logo/media; fallback rename to Lumen; keep the code MIT and the fork relationship obvious. |

---

## 8. v0.1 acceptance criteria (release gate)

A build is v0.1.0 only when all of these are true:

- [ ] `cargo build --release -p horizon-lite` on Linux x86-64 from a clean checkout, with `Cargo.lock`, toolchain 1.95.
- [ ] Binary ≤56 MB (stripped), SHA-256 published; no prebuilt binaries in the repo.
- [ ] Fresh install: `horizon-lite prepare` finds a 26.3 install, explains the server jar, completes in ≤5 min, and makes no network call.
- [ ] Create a world (seed 1234, default), break a block, place a block, save, quit, reopen; all succeed.
- [ ] The same save opens in vanilla 26.3; a vanilla save opens in Lite; `save_roundtrip`/`world_reopen`/`datafix` pass on the sample.
- [ ] Worldgen sample: 100 chunks per dimension match upstream at the pinned base (hash compare).
- [ ] No `AF_INET`/`AF_INET6` socket in a 60 s single-player session (`strace`). Tier B: none until "Open to LAN"; then LAN discovery broadcast + listen/accept only, no outbound to a non-local address.
- [ ] LAN: a vanilla 26.3 client joins a Lite world; a Lite client joins a vanilla LAN world; 2 players, 5 minutes, no disconnect.
- [ ] Resource pack: a vanilla 26.3 pack loads; a pack with a broken model is refused with a clear error, not a crash.
- [ ] Time to title ≤3.2 s; first block ≤6 s existing world, ≤15 s new world (reference machine, median of 5).
- [ ] `LICENSE`, `THIRD_PARTY_NOTICES.md`, `FORK.md`, `UPSTREAM.md`, `docs/lite/*` present and accurate; README has the Mojang disclaimer and the unofficial-fork sentence.
- [ ] `check_public_tree.py`, `check_lite_scope.py`, `cargo fmt`, `clippy -D warnings`, `cargo test` green.
- [ ] No upstream workflow, secret, release key, endpoint, or "claim" instruction remains.
- [ ] Release notes state the base commit, MC version, what was removed, and how to report Lite bugs.

---

## 9. README elevator pitch

> **Horizon Lite is an unofficial, single-player-first fork of [Horizon](https://github.com/horizon-rust/horizon), the from-scratch Rust reimplementation of Minecraft: Java Edition 26.3.** It keeps the part that matters — vanilla world generation, saves, mobs, villagers, redstone, commands and all three dimensions — and removes the part that needs the internet: accounts, server browsing, telemetry, the launcher, mods, shader packs and the dedicated server. Open to LAN is there when you want to play with someone in the same room; otherwise it never touches the network. You prepare it once from the copy of Minecraft you already own, and it opens and writes worlds vanilla can open: one native binary, no Java at runtime, no sign-in, no background connections. MIT, with upstream credited and the fork relationship stated up front.

---

## Appendix A — LOC accounting (estimate, not compiler-verified)

Method: `find`/`wc` over `.rs` at the pinned base. "Removed" = crates deleted whole + feature files identified by path, minus shared files that must stay for single player. Exact numbers will move after the trim; re-measure with `cargo metadata` and `tokei`.

| Removal set | LOC |
|---|---:|
| `launcher/` | 114,508 |
| `horizon-server` + `horizon-server-files` + anticheat + chat-filter | 24,860 |
| `horizon-friends` + `horizon-relay` | 7,052 |
| `horizon-cosmetics` | 6,343 |
| mods: `horizon-mods`, `cargo-horizon-mod`, `horizon-port-pack`, `horizon-mod-registry`, `horizon-mod-api-gen`, `horizon-mod-deps` | 30,209 |
| shaders: `horizon-shaders` + `horizon-shader-api` | 29,649 |
| packs: `horizon-optifine` + `horizon-polytone` | 13,252 |
| telemetry: `horizon-telemetry` + `horizon-telemetry-server` + `horizon-bench` | 10,130 |
| `horizon-bots` + `horizon-release-sign` | 3,366 |
| `horizon-hdr` | 330 |
| client feature files: studio, realms, extras, agent control, server list, dedicated, outbound net, splitscreen, distant terrain, cosmetics/friends/mods glue, pack UI, shader UI, Discord, heartbeat | ~53,900 |
| **Tier A total** | **~298,000 (20.6%)** |
| Tier B adds back resource packs (packs + OptiFine, ~17.9k) and LAN socket/UI (~4.3k) | **~285,000 (19.7%)** |
| Tier C keeps core + world + client-core + items + command + protocol | **~298,000 left; ~1,146,000 removed (79.4%)** |

The important number is the *remaining* one: Tier A/B still contains ~1.15M Rust LOC. That is the game. "Lite" is a surface reduction, not a codebase reduction. If the goal is a <10 MB binary, this is the wrong project; that would require deleting the renderer or worldgen and would no longer be Horizon.

## Appendix B — measurement protocol

Reference machine: Linux x86-64, Ryzen 7 9800X3D / Apple M4 Pro, 32 GB, NVMe, GPU with Vulkan, 1280×720 window, VSync off, render distance 16, simulation distance 16, no packs, prepared resources on a warm OS cache. Median of 5 runs.

- **Time to title:** process start → first frame of the title screen.
- **Time to first block:** process start → "Play Selected World" → first frame with terrain → scripted break of the block at the player's feet accepted and its drop visible. Existing world and fresh world (seed 1234) measured separately.
- **Binary size:** `stat -c%s` of the stripped release binary; report install size separately (binary + prepared resources, which come from the user's copy).
- **No-network:** `strace -f -e trace=network -o /tmp/lite-net.log ./horizon-lite --game-dir /tmp/lite-scratch` for 60 s; fail on any `AF_INET`/`AF_INET6` `socket`/`connect`. For Tier B, repeat with LAN on; allow the LAN discovery broadcast, `bind`/`listen`/`accept` on the chosen port, and connections from private addresses only — fail on any outbound connection to a non-local address.
- **Save round-trip:** upstream `save_roundtrip`, `world_reopen`, `datafix`; plus open the Lite save in vanilla 26.3 and a vanilla save in Lite.
- **Worldgen:** upstream `chunk_generation`/`worldgen` sample, 100 chunks per dimension, hash compare against upstream at the pinned base.
- **LAN:** `lan_e2e` + a real vanilla 26.3 client join (dev-only, from the owner's own files).

## Appendix C — first-week tasks (before writing code)

1. Create `Solenopsisbot/horizon-lite` as a **new** repo; push full history from `4e6920a3`; set `upstream` fetch-only.
2. Replace `AGENTS.md` and `CONTRIBUTING.md` with Lite versions; add the `STOP` banner; archive the upstream copies under `docs/upstream/`.
3. Delete upstream `.github` workflows/templates/governance; add `ci.yml` and `lite.yml`.
4. Write `FORK.md`, `UPSTREAM.md`, `docs/lite/SCOPE.md`, `PARITY.md`, `LICENSING.md`, `BRANDING.md`.
5. Trim the tree in small commits: launcher → server/telemetry/friends → mods/shaders/packs → client extras. `cargo test` after each.
6. Add `crates/horizon-lite` thin binary + `horizon-lite-prepare` wrapper; rename the window title/About/`--version`.
7. Add `tools/check_lite_scope.py` and the no-network integration test.
8. Build the first binary; measure baseline binary size/TTFB; publish `PARITY.md` with "not yet measured" rather than a claim.
