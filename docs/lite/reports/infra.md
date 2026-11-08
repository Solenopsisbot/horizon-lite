# Horizon Lite — infrastructure slice

Scope: everything in `upstream` that is **not the game binary**.
All numbers measured on the read-only checkout (no cargo run). `git log` = 22,320 commits,
`.git` = 235 MB, working tree = 139 MB excluding `.git`/`target`.

---

## 0. Baseline numbers

| Measure | Value |
|---|---|
| Rust LOC (all, excl. `target/`) | **1,618,600** |
| ├ `crates/` | 1,328,595 (2,386 files) |
| ├ `third_party/` | 174,735 (219 files) |
| ├ `launcher/` | 114,508 (223 files) |
| └ `xtask/` + `tools/*.rs` | 536 + 226 |
| Python LOC | **158,162** (`tools/` 144,690 + `tests/` 13,441) |
| Java LOC | **52,656** (380 oracle/exporter files under `mods/`) |
| Markdown LOC | **40,064** |
| Workspace members | **40** listed + 4 `exclude`d dirs |
| `[patch.crates-io]` entries | 3 (`wgpu-hal`, `naga`, `libmimalloc-sys`) |
| CI workflows | **22 files, 2,790 lines** |
| Parity harnesses | **569** `tools/test_*_parity.py` |
| Cargo examples (parity probes) | **352** files, 69,452 LOC |

---

## 1. Area-by-area verdicts

| Area | LOC / files / size | Verdict | Why | Risk |
|---|---|---|---|---|
| `crates/` game slice (29 of 40 members reachable from `horizon-client`) | 1.33M / 2,386 | **GATE** | Only the 29-crate closure is needed to play. Per-crate detail in §2. | Editing `Cargo.toml` files to drop crates cascades; each removal needs a `cargo check`. |
| `crates/horizon-polytone` | 1,817 / 9 | **CUT** | **Orphaned**: no crate in the workspace depends on it (`grep horizon_polytone` → 0 hits). Dead weight in every `--workspace` build. | None. Free 1.8k LOC. |
| `crates/horizon-telemetry-server`, `crates/horizon-mod-registry` | 5,834 / 3,602 | **CUT** | Separate workspaces (axum + rusqlite) — hosted services for Horizon's telemetry and mod index. Not built by the game workspace, but they sit in the tree and CI builds them. | None for the game. |
| `crates/horizon-bots` (1,784), `horizon-port-pack` (15,899), `cargo-horizon-mod` (840), `horizon-relay` (2,377) | 20,900 | **CUT** | Load-test bots, Java-modpack porting pipeline, `cargo horizon-mod` mod-author CLI, Play-with-Friends relay. All dev/network tooling. | `horizon-client` has an optional `friends` feature → drop the feature with `horizon-extras`. |
| `launcher/` | 113,794 / 223 | **CUT** (recommended) or **GATE** | Separate workspace, own `Cargo.lock`, own CI job. 48 UI files = 31,403 LOC of GPUI. 99 CLI subcommands. Nothing in `crates/` depends on it. See §3. | Losing Microsoft sign-in + auto-update. Lite is single-player-first, so acceptable. |
| `packaging/` | 33 files / 320 K | **GATE** | Keep `icons/` (a **hard build input**: `crates/horizon-client/build.rs` embeds `packaging/icons/horizon.ico` on Windows and `rerun-if-changed` it) + `linux/horizon.desktop` + `PLAY.txt`. Cut `macos/`, `server/` (amp, Docker, pterodactyl). | Removing `packaging/icons/` breaks the Windows build script (it silently warns only when `CI` is unset; on CI it panics). |
| `.github/workflows/` | 22 files / 2,790 | **REPLACE** | 6 self-hosted runner pools (`horizon-checks`, `horizon-light`, `horizon-game`, `horizon-nightly`, macOS mini, playhorizon), 4 secrets (`RELEASE_SIGNING_KEY[_NEXT]`, `HORIZON_CURSEFORGE_API_KEY`), 5 repo vars. None of it transfers. See §4. | A naive copy silently no-ops (skipped jobs count as passed). |
| `xtask/` | 536 / 2 | **KEEP** | `package`, `package-server` build the playable folder; `tokens` regenerates `crates/horizon-theme/tokens.css`; `mod-api` regenerates the native hook catalog. All four are needed. | `package` shells out to `git archive` — the repo must stay a git checkout. |
| `.githooks/` | 2 files | **KEEP (rewrite)** | Only guard against committing Mojang jars/assets (`.local/`, `*.jar`) — still valuable. Both hooks `exec tools/check_public_tree.py`. | If you cut `tools/`, the hooks fail on every commit. |
| `tools/` | 1,101 files / 144,690 py + 226 rs / 14 MB | **GATE** | 780 `tools/*.py` at top level: 569 parity harnesses, 65 corpora, 34 e2e, rest generators/benchmarks/release. **`tools/native-hook-fragments/` (160 JSON, 652 K) is a hard build dependency** — see §5. | Blind `rm -rf tools` breaks every build. |
| `tests/` | 153 files / 13,441 | **GATE** | 147 `unittest` files; 59 import `tools/test_*_parity` (vanilla diffing), 88 test repo infra (release train, nightly, parity runner, triage, claim bot, roadmap). Keep ~12. | Removing `tests/` removes CI's only Python step; cheap to keep, so prune by dependency instead. |
| `benchmarks/` | 250 dirs / 394 files / 17 MB | **CUT** | Recorded results of past parity/benchmark runs (`rust-*-2026-10-06/scoped-parity.json`). Historical artefacts, zero code. | None. |
| `docs/` | 247 files / 35,313 md / 13 MB (8.6 MB `media/`) | **GATE** | Keep ~15: `architecture.md`, `native-client.md`, `forking.md`, `parity-workflow.md`, `horizon-ctl-commands.md`, `server.md`, `mods.md`, `release-flow.md`, `build-times.md`, `ci-runners.md`. Cut `parity/` (708 K), `performance/` (624 K), `native-mods.md` (512 K), `api/` (204 K), `media/` (8.6 MB). | `tests/test_docs_readme_links.py` checks every README link — rewrite or drop. |
| `roadmap/` + `ROADMAP.md` | 156 K + 916 lines | **CUT** | `roadmap.toml` feeds playhorizon.dev/hub and X posts. Pure Horizon release-marketing state. | `tools/roadmap.py` and `tests/test_roadmap.py` go with it. |
| `research-lock.json` | 71 lines | **KEEP** | Pins MC 26.3, client/server jar SHA-1s, accepted manifests, Java major 25, Vineflower. Read by `horizon-prepare` **and** `tools/lab.py`; `horizon-prepare` also hashes it into the exporter cache key. | Editing it invalidates every prepared resource and exporter bundle. |
| `native-hooks.json` | 5,223 lines / 152 K | **KEEP** | **Build input.** `horizon-mod-api-gen/src/build.rs` reads it on every build; `crates/horizon-client/src/game/native_hooks.rs` `include_str!`s it in a test. Generated by `xtask mod-api` / `tools/stamp_native_hooks.py`. | Never hand-edit; regenerate. |
| `THIRD_PARTY_NOTICES.md` | 311 lines | **KEEP** | MIT licence obligations for wgpu-hal, naga, mimalloc, Pixelify Sans, Pixelarticons, Hugeicons, FidelityFX, Catnip/Ponder, mod-loader logos, plus a "code removed for its license" history. | Dropping it weakens your licence position on the three `[patch]` crates. |
| `third_party/` | 219 files / 174,735 / 8.4 MB | **GATE** | See §5 — all three are real runtime fixes, not vanity forks. | Removing any requires deleting its `[patch]` line **and** re-resolving `Cargo.lock`. |
| `mods/` | 384 files / 52,656 java / 4.5 MB | **GATE** | `mods/horizon/src/test/java/dev/horizonlab/parity/` (375 files) is **not a test fixture — it is the resource preparer's Java source**, compiled by `horizon-prepare` at first run (`const PARITY: &str`). Cut `src/bench`, `src/neoforge-bench`, `src/neoforge-oracle`. | Deleting `src/test/java` makes `horizon-prepare` unable to build resources → unplayable. |
| `research` / `.claude/skills/vanilla-parity` | 16 K | **CUT or KEEP** | Skill doc for porting against the ledger. Keep if you keep `port_ledger.py`. | None. |

---

## 2. Recommended repo shape for `horizon-lite`

```
horizon-lite/
├─ Cargo.toml            # workspace, 30 members
├─ Cargo.lock            # regenerate once after pruning (see §5)
├─ rust-toolchain.toml   # edition 2024, rust-version 1.95
├─ clippy.toml
├─ LICENSE               # MIT + THIRD_PARTY_NOTICES.md
├─ THIRD_PARTY_NOTICES.md
├─ README.md             # rewritten: build, prepare, play, nothing else
├─ research-lock.json    # KEEP verbatim
├─ native-hooks.json     # KEEP verbatim
├─ crates/               # 30 crates (list below)
├─ third_party/          # 3 patched crates (or 2, see §5)
├─ mods/horizon/src/test/java/   # 375 files, the preparer's Java
├─ packaging/icons/              # build input
├─ tools/                # ~15 files, see below
├─ tests/                # ~12 files, see below
├─ docs/                 # ~15 files
├─ xtask/
├─ .github/workflows/ci.yml      # one file
└─ .githooks/{pre-commit,pre-push}
```

**Deleted outright:** `launcher/`, `benchmarks/`, `roadmap/`, `ROADMAP.md`,
`crates/{horizon-polytone,horizon-bots,horizon-port-pack,horizon-relay,horizon-friends,cargo-horizon-mod,horizon-telemetry-server,horizon-mod-registry}`,
`mods/horizon/src/{bench,neoforge-bench,neoforge-oracle}`,
`packaging/{macos,server}`, `.claude/`, `docs/{media,parity,performance,api,modpacks}`.

**Exact surviving workspace members (30):**

```toml
[workspace]
resolver = "2"
members = [
  "crates/horizon-core",
  "crates/horizon-world",
  "crates/horizon-items",
  "crates/horizon-command",
  "crates/horizon-assets",
  "crates/horizon-protocol",
  "crates/horizon-client-core",
  "crates/horizon-client-input",
  "crates/horizon-client-render",
  "crates/horizon-client",
  "crates/horizon-client-lib",
  "crates/horizon-cosmetics",
  "crates/horizon-optifine",
  "crates/horizon-shaders",
  "crates/horizon-shader-api",
  "crates/horizon-mods",
  "crates/horizon-mcp",
  "crates/horizon-mod-api-gen",
  "crates/horizon-mod-api-gen/dispatch-tests",
  "crates/horizon-mod-deps",
  "crates/horizon-server-files",
  "crates/horizon-server",
  "crates/horizon-anticheat",
  "crates/horizon-chat-filter",
  "crates/horizon-narrator",
  "crates/horizon-hdr",
  "crates/horizon-dualsense",
  "crates/horizon-theme",
  "crates/horizon-threads",
  "crates/horizon-telemetry",
  "crates/horizon-bench",
  "crates/horizon-prepare",
  "crates/horizon-release-sign",
  "xtask",
]
```

(34 named entries; drop `horizon-server` + `horizon-release-sign` for a client-only lite.)

**Kept in `tools/` (~15 files, ~6 k LOC):**
`native-hook-fragments/` (build input), `lab.py` (helpers the prepare path reuses), `prepare_output.py`,
`compare_prepare.py`, `check_prepare_exporters.py`, `stamp_native_hooks.py`, `gen_version_consts.py`,
`check_public_tree.py`, `check_pe_arch.py`, `check_imports.py`, `build_times.py`,
`ci/rust_changes.py`-equivalent (rewrite), `release_train.py` (delete — replace with a tag push).
Everything else goes.

**Kept in `tests/` (~12 files, ~2 k LOC):** `test_check_imports.py`, `test_check_pe_arch.py`,
`test_gen_version_consts.py`, `test_stamp_native_hooks.py`, `test_prepare_exporters.py`,
`test_prepare_output.py`, `test_game_home.py`, `test_docs_readme_links.py`,
`test_install_sh_signature.py`, `test_lab.py`, `test_build_times.py`, `test_ci_rust_changes.py`.

**Branch / CI strategy.** One branch `main`, no release train, no nightly, no parity-on-main.
Tags are plain `vX.Y.Z` pushed by hand. CI = one workflow, two jobs:
`verify` (fmt + clippy `-D warnings` + `cargo test --workspace --lib --bins --tests` +
`python -m unittest discover -s tests`, hosted `ubuntu-latest`, 45 min) and
`build` (`cargo build --release -p horizon-client -p horizon-client-lib --bins -p horizon-prepare`,
then `cargo run -p xtask -- package`, uploaded as an artifact — **unsigned, no secrets**).
Windows/macOS compile jobs optional, on `windows-latest` / `macos-latest`, `continue-on-error: true`.

Expected LOC after the cut: **~1.40M Rust** (from 1.62M — −114 k launcher, −37 k dropped
crates, −69 k parity examples), **~10 k Python** (from 158 k), **~52.7 k Java** (unchanged — it is
a product dependency), **~6 k Markdown** (from 40 k).
Working tree: **139 MB → ~75 MB** (63 MB of it is `crates/`; `third_party` is 8.4 MB, or 3.4 MB
without naga).

---

## 3. The launcher question

The key finding: **a no-launcher flow already exists and is documented in `README.md` §"Build from source"**:

```sh
cargo run --release -p horizon-prepare -- --prepare --server-jar ~/Downloads/server.jar   # JDK 25
cargo run --release -p horizon-prepare -- sounds                                         # optional
cargo run --release -p horizon-client
```

`horizon-prepare` is a **standalone headless CLI** (`crates/horizon-prepare/src/main.rs`, 368 LOC over an
7,995-LOC lib; `--prepare`, `--check`, `--launch-api`, `--progress json`, `--output`, `--minecraft-dir`,
`--prism-dir`, subcommands `compile-exporters`/`sounds`/`panorama`/`fonts`/`packs`/`languages`).
It never downloads Minecraft; it imports the player's own copy and verifies against `research-lock.json`.
Exit codes are 0/1/2, so it is scriptable.

`horizon-client` takes `--resources <dir> --world <name> [--creative] [--game-dir <dir>]` and starts
single-player with **no account at all** (MS sign-in only gates `play` through the launcher and
multiplayer). `horizon-ctl` (2,635 LOC, `crates/horizon-client/src/bin/horizon-ctl/`) is the second
headless entry point: a local socket + MCP server that can drive the game (`launch --offscreen --wait`,
`state`, `command`, `screenshot`, `quit`).

### Option A — keep the full launcher
**Effort:** 0 (copy). **Size:** +113,794 LOC + 10 MB `launcher/lang` (86 locales) + a second
`Cargo.lock`, GPUI/wgpu/oo7/keyring deps, 45-min CI job.
**Player flow:** double-click → sign in with Microsoft → install Nightly (signed, from `horizon-rust/horizon`
releases — **not your repo**) → prepare → Play.
**Fatal for lite:** the launcher hard-codes `horizon-rust/horizon` release endpoints and
`horizon_release_sign::trusted_keys()` from `crates/horizon-release-sign/release-keys.txt`. You would be
shipping an updater that installs Horizon's official signed binaries over your own game. You'd need to
repoint the release URL, own a signing key (`tools/ci/new_release_key.sh`), and publish releases — i.e.
rebuild the whole release train. **Verdict: no.**

### Option B — strip to a headless CLI
**Effort:** **3–5 days.** `backend.rs` (7,208 LOC) and `cli.rs` (4,017 LOC) are already gpui-free — `cli.rs`
imports only `horizon_launcher::{...}` + `clap` + `std`, and touches exactly three `crate::` items
(`i18n`, `mcp`, `perf`). Work:
1. Split `horizon-launcher` into two packages: `horizon-launcher-core` (lib: `backend`, `instances`,
   `launch`, `java`, `download`, `sources`, `mojang`) and keep `horizon-launcher` (GPUI bin) on top. Or
   just delete the GUI and keep the lib.
2. Add `[[bin]] horizon-lite` → `cli.rs` with a shim module for `i18n`/`perf`; drop the 99 subcommands
   down to ~12 (`versions`, `install`, `prepare`, `play`, `import-build`, `settings`, `java list/install`,
   `instance create/select/list`, `worlds list`).
3. Delete `account.rs` (2,469 LOC), `mcp.rs`, `native_mods.rs` (5,001), `rust_toolchain.rs` (1,514),
   `wardrobe*`, `shop*`, `servers*`, `browser/`, `github*`, `telemetry.rs`, `update_handoff.rs`.
4. **No signing, no updater**: `install` becomes "unpack a folder you built or downloaded"; `check` is a
   SHA-256 against a `SHA256SUMS` you publish.
**Resulting size:** ~8–12 k LOC, one small binary, no GPUI/wgpu/oo7/keyring.
**Player flow:** `horizon-lite prepare --minecraft-dir ~/.minecraft && horizon-lite play --world W`.
**Verdict: only worth it if you want a GUI-less but friendly `install/prepare/play` triple.** You can get
90 % of it in **1 day** with a 150-line shell script around the two existing binaries.

### Option C — no launcher (recommended)
**Effort:** **0.5 day** — write `README.md` + a `play.sh` wrapper.
**Player flow:**
```
1. install Rust 1.95+, Python 3.10+ (tools only), JDK 25, libasound2-dev libudev-dev
2. play MC 26.3 once in the official launcher; download the 26.3 server jar
3. cargo build --release -p horizon-client -p horizon-client-lib --bins -p horizon-prepare
4. ./target/release/horizon-prepare --prepare --server-jar ~/Downloads/server.jar
5. ./target/release/horizon-prepare sounds          # optional, ~380 MB
6. ./target/release/horizon-client --resources .local/horizon-client/26.3 --world MyWorld
```
**Verdict: take this.** It is already the upstream-supported path, needs no accounts, no signing, no
updates, no network services, and it is the only option where `horizon-lite` is genuinely a *source-only*
repo. Revisit Option B only if non-technical players appear.

---

## 4. Build / test time and CI implications

Measured/declared costs in the Horizon repo (no builds run here):

| Cost centre | Horizon | Lite |
|---|---|---|
| Cold `cargo build -p horizon-client --profile dev` | dominant unit is `syn` + `horizon-mod-api-gen` (parses all of `game/`, 13,391-line `native_hooks.rs`; ~6 s/rebuild unoptimised, ~1.5 s at `opt-level=3` — already overridden in `[profile.dev.package]`) | unchanged; **the build script is on the critical path for every `horizon-client`/`-render` rebuild** |
| `cargo test --workspace --lib --bins --tests` | CI `verify` job, 45-min timeout, one runner | same, minus 12 crates |
| `cargo clippy --workspace --all-targets` | includes **352 examples / 69,452 LOC**; ci.yml explicitly notes examples "were most of this step's build and link time" | **delete the 352 `examples/` probes** → biggest single win (est. 40–60 % of clippy time) |
| Launcher check job | separate workspace, 45-min timeout | gone |
| Parity | `parity.py --all` = 26 min on a Mac mini; a core-crate PR reruns ~350 harnesses = 60–90 min; `parity-main` on every merge | gone |
| Release build | 6-platform matrix (linux, linux-musl, windows, windows-arm64, macos-arm64, macos-x64), 40–60 min each, + notarisation, + signing | 1 platform, `cargo build --release` + `xtask package`, no secrets |

**CI implications of no Horizon release infra.** You lose, and must not pretend otherwise:
`RELEASE_SIGNING_KEY`/`_NEXT`, `HORIZON_CURSEFORGE_API_KEY`, `MACOS_SIGN_IDENTITY`, `HORIZON_MSA_CLIENT_ID`,
the `horizon-checks`/`horizon-light`/`horizon-game`/`horizon-nightly` self-hosted pools,
`RELEASES_PAUSED`/`SELF_HOSTED_CI`, and the Mac mini that holds the maintainer's own Minecraft files.
Consequences:
- `tools/pr_ready.py` must be gutted (it calls `origin/main`, `--host macmini`, `parity.py --changed`).
- `tools/ci/rust_changes.py` imports `tools/release_train.py` — cut both, or replace with a 20-line
  `git diff --name-only | grep -v '\.md$'` gate.
- **`verify` is the only required check.** A skipped job counts as a pass on GitHub, so never gate the
  real compile behind a path filter you don't control.
- Lite CI cannot run the vanilla harnesses at all (they need the real 26.3 jars). Accept that the port
  is frozen at the commit you forked from: **you have no way to verify behaviour against vanilla any more.**
  Keep `tools/port_ledger.py` + `mods/.../parity/*.java` if you ever want to revive it.

---

## 5. Traps

1. **`tools/native-hook-fragments/` is a build dependency, not a dev tool.**
   `horizon-mod-api-gen/src/build.rs::track()` does `fs::read_dir(root.join("tools/native-hook-fragments"))`
   and returns `Err` on failure; `horizon-client/build.rs` `.expect("generating native mod API")` → panic.
   Delete `tools/` wholesale and **every build fails** in `horizon-client` and `horizon-client-render`.
   Keep the 160 JSON files (652 K). Same for `native-hooks.json` and `crates/horizon-client/src/mod_api.rs`
   (both `rerun-if-changed` *and* parsed).

2. **`build.rs` codegen is load-bearing and slow.** `horizon-mod-api-gen` parses all of
   `crates/horizon-client/src/game/**/*.rs` with `syn` on every rebuild of the client crate. `Cargo.toml`
   already pins `opt-level = 3` for `syn`/`proc-macro2`/`horizon-mod-api-gen` in dev, release **and**
   `fast` profiles — do not "clean up" those lines. `horizon-world/build.rs` hashes `Cargo.lock` and both
   `src/` trees to key its snapshot cache; a missing `Cargo.lock` silently disables the cache.

3. **`packaging/icons/horizon.ico` is a build input.** `crates/horizon-client/build.rs` embeds it as a
   Windows resource and derives `rustc-link-arg-bin=horizon-client=/STACK:8388608` (splitscreen needs the
   8 MB stack). Point it at your own icon rather than deleting it.

4. **`[patch.crates-io]` — keep 2 of 3.**
   - `third_party/wgpu-hal`: fixes a **real crash** (Intel HD 520/530/UHD 620/630 access violation from
     wgpu 30's descriptor-pool creation), macOS HDR colour-space crash, and Windows Vulkan VSync-off frame
     stalls. **KEEP** unless you drop pre-Ice-Lake Intel and macOS HDR.
   - `third_party/libmimalloc-sys`: mimalloc v3 uses POPCNT on MSVC x86 → **dies before `main`** on
     pre-Nehalem CPUs. 1.2 MB. **KEEP** (cheap insurance).
   - `third_party/naga`: GLSL-frontend fixes **only needed by shader packs**. If lite drops
     `horizon-shaders`, **CUT** — this is the one you can lose (5 MB, biggest of the three).
   Removing any entry means also deleting its `[patch.crates-io]` line **and** re-resolving `Cargo.lock`
   (the lockfile currently records the patched sources; `--locked` will fail).

5. **The Java exporter dependency is *not* optional, and not a test fixture.**
   `crates/horizon-prepare` compiles `mods/horizon/src/test/java/dev/horizonlab/parity/*.java` (375 files)
   with `javac --release 25` on first prepare, then runs 5 JVMs. Without a **JDK 25** the game cannot
   produce its resources and is unplayable. Releases sidestep this by shipping a precompiled `exporters/`
   bundle (gitignored: `/exporters/`) — a source-only repo cannot, so document "install JDK 25" loudly.
   `--check` is the one Java-free path (exit 0/1).

6. **`.local/` is mandatory and gitignored.** Prepared resources go to
   `<root>/.local/horizon-client/<version>` (default), scratch to `<root>/.local`. It is also the
   exporter cache (`.local/exporters/<sha256>`) and the parity state. Two consequences: the repo root
   must be writable, and `xtask package` uses `git archive HEAD` so a release folder always starts from a
   clean tree.

7. **No git-LFS — but 13 MB of binary in `docs/` and 17 MB in `benchmarks/`.** `git lfs` is not
   installed and `.gitattributes` only pins `eol=lf` for four generated files. Nothing breaks if you cut
   those trees; just don't try to "re-add them later" without thinking about `.git` size (235 MB today).

8. **`Cargo.lock` granularity.** `crates/horizon-mod-deps` (2 LOC, empty lib) exists **solely** to keep
   registry crates in `Cargo.lock` so native mods can name them (`docs/native-mods.md`). If you drop native
   mods, drop it; if you keep them, keep it or mod builds break.

9. **`research-lock.json` is a cache key.** `horizon-prepare` hashes it plus every exporter `.java` into
   the exporter bundle key. Touching it (e.g. adding an "accepted manifest") invalidates every player's
   prepared resources.

10. **Two `Cargo.lock`s.** The root lockfile and `launcher/Cargo.lock` are independent. Deleting
    `launcher/` also deletes 191 KB of lockfile and the `launcher` CI job — make sure
    `.github/dependabot.yml` (absent) or any `cargo update --workspace` script doesn't reach for it.
