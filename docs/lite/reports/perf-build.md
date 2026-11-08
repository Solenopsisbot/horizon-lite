# Horizon Lite — build & startup speed audit

Scope: how `target/*/horizon-client` is produced and how it reaches its first frame.
Read-only audit; no builds were run in the repo. Measurements quoted from the tree are
marked **claimed** (a code comment or doc) or **measured here** (a read-only inspection of
`target/fast/horizon-client` and of rustc's own link line).

Machine used for inspection: Ryzen 7 3700X (Zen 2, AVX2/FMA/BMI2, no AVX-512), 16 threads,
Linux, `rustc 1.99.1` (LLVM 23.1.1), system LLVM 23.1.3, `ld.gold` + clang present,
no `mold`, no `llvm-bolt`. Workspace `rust-version = "1.95"`.

---

## 0. TL;DR

| Verdict | Item |
|---|---|
| **Keep** | mimalloc. It is statically linked (156 `mi_*` symbols in the binary), built release (`MI_DEBUG=0`, `MI_BUILD_RELEASE`), no `alloc-census` overhead in normal builds. |
| **Fix** | `horizon_threads::configure_allocator()` forces `mi_option_purge_delay = 0` (purge pages back to the OS on every free). That is the memory-optimal / speed-pessimal setting and it *overrides* `MIMALLOC_PURGE_DELAY`. |
| **Best runtime lever** | PGO (5–15%), then `target-cpu` (2–8%), then `lto="fat"` (1–4%), then BOLT (3–8%). |
| **Best startup lever** | `Renderer::new` compiles ~74 shader modules and ~82 pipelines on the main thread *before the loading screen can draw*. On DX12 the repo measures 2.6 s FXC / ~1 s DXC for ~65 pipelines; Vulkan is the same order with a cold driver cache. This is the time-to-first-frame. |
| **Free wins** | Persist a `wgpu::PipelineCache` on Vulkan/Metal (none is used today), move the log-rollover gzip off the main thread, stop creating `GpuTimer` when nothing reads it, and stop formatting descriptor strings in `Reuse` on the first (no-previous) renderer. |
| **Non-levers** | Dropping the `gles`/`dx12` wgpu backends or naga `hlsl-out`/`spv-out`/`msl-out` changes binary size and build time only — 0 % runtime. |

There is already in-progress speed work in the tree: `Cargo.toml` has an uncommitted
`[profile.lite]` and `scripts/build-speed.sh` is untracked. It is sound but has three
concrete problems (panic=abort rationale is wrong, PGO trains only the benchmark's
synchronous-startup path, and it prefers the system `llvm-profdata`). Review in §1.2.

---

## 1. What exists today

### 1.1 Profiles (`Cargo.toml:75-115`)

```toml
[profile.dev]  debug = "line-tables-only"
[profile.dev.package.{horizon-mod-api-gen,syn,proc-macro2}]  opt-level = 3
[profile.release]  lto = "thin"  codegen-units = 1
[profile.release.package.{horizon-mod-api-gen,syn,proc-macro2}]  opt-level = 3
[profile.fast]  inherits = "release", lto = false, codegen-units = 16, incremental = true
[profile.lite]  inherits = "release", lto = "fat", codegen-units = 1, panic = "abort",
                debug = 0, incremental = false        # uncommitted
```

* No `.cargo/config.toml` and no `rust-toolchain.toml` in the tree.
* `release`/`lite` keep `opt-level = 3` (Cargo default), `debug-assertions = false`,
  `overflow-checks = false`, `incremental = false`, `strip = "none"`.
* `fast` is for iteration only (`incremental = true` and 16 CGUs deliberately trade runtime).

### 1.2 Review of `scripts/build-speed.sh`

Correct and worth keeping: fat LTO profile, `target-cpu=native`, separate PGO pass,
`-Cllvm-args=-pgo-warn-missing-function`, training through the built-in benchmark.

Fix these:

1. **The `panic = "abort"` comment is false.** `Cargo.toml` says "the game has no
   `catch_unwind` paths it can recover from". It has several production ones:
   * `crates/horizon-threads/src/jobs.rs:436` — a panicking chunk job loses the job, the
     worker and the pool survive (this is the pool's documented contract).
   * `crates/horizon-client-render/src/crash.rs:77` (`crash::contain`) — a shader pack's
     panic is logged and the pack is dropped (`gfx.rs:7122`, `gfx/pack_post.rs:980`).
   * `crates/horizon-client/src/save.rs:2362` — a datafix panic becomes "upgrading an
     older record failed" instead of killing the save.
   * `crates/horizon-client/src/game/dedicated.rs:1295,1342` — a tick panic still saves
     the world before the server stops.
   * `crates/horizon-client/src/lod_net/server.rs:208`.
   With `panic=abort` all of these become `SIGABRT` at the panic site. For a single-player
   speed build that is defensible (the panic hook still writes the crash report and, on a
   worker, still `exit(101)`s), but the comment must say so, and the dedicated-server
   build must not use this profile.

2. **PGO trains the wrong startup path.** `--benchmark` sets
   `synchronous_startup() == true` (`crates/horizon-client/src/game/resource_load.rs:48-60`),
   so the instrumented run never executes `run_loading`, `Loading::draw`,
   `startup_menu`, or `set_ui`. Add one *normal* launch (loading screen → title → world,
   60–90 s) to the training set. (§5.)

3. **`llvm-profdata` selection prefers the wrong binary.** `command -v llvm-profdata`
   finds `/usr/bin/llvm-profdata` (23.1.3) here; rustc's is
   `$(rustc --print sysroot)/lib/rustlib/<host>/bin/llvm-profdata` (23.1.1). Use the
   sysroot one first; profile-format skew between point releases is a needless risk.

4. Minor: the script references `docs/lite/PERFORMANCE.md`, which does not exist
   (dangling doc). The instrumented build uses the `lite` profile, i.e. fat LTO *with*
   instrumentation — roughly 2× the build time for identical counts. Use a `lite-pgo`
   profile with `lto = "thin"` (§3).

5. Minor: `HORIZON_NO_DISCORD` / `HORIZON_NO_HEARTBEAT` are no-ops in Lite's default build
   (both features are off), harmless.

### 1.3 The linker is already the good one

Measured here by compiling a hello-world with a logging linker wrapper
(`rustc -O -C linker=$PWD/wrap.sh`): rustc 1.99.1 on this target emits
`-fuse-ld=lld`, `-Wl,--gc-sections`, `-Wl,--as-needed`, `-Wl,-O1` by itself.
So `--gc-sections` and lld are already in effect; `mold` is not installed and would only
shorten *builds*, not frames. Nothing to add on Linux. On Windows, MSVC `link.exe`
already runs with `/OPT:REF,ICF` from rustc.

---

## 2. Allocator audit

**What is linked.** `crates/horizon-client/src/main.rs:4-9` installs
`horizon_threads::Allocator = mimalloc::MiMalloc` unless `system-allocator` or
`alloc-census` is on. `horizon-threads/Cargo.toml` uses `mimalloc 0.1.52`
(`default-features = false`) and `libmimalloc-sys 0.1.49` (`extended`), both patched to
`third_party/`. No jemalloc/tcmalloc/snmalloc anywhere. Measured in
`target/fast/horizon-client`: 156 `mi_*` symbols, `ldd` shows only
libc/libm/libgcc_s/libasound — mimalloc is static, `override` is off, so C libraries
(ALSA, the Vulkan loader) keep glibc malloc. That is the right shape.

**Census/tagging overhead in normal builds: zero.** `heap_tag()` is
`HEAP_CENSUS.then(...)` with `HEAP_CENSUS = cfg!(feature = "alloc-census")`, a const
`false`, so it folds away; `CensusAllocator` and its 16-byte block header exist only
behind the feature. `spans::startup::step()` likewise becomes
`(traced || false).then(...)`.

**Is mimalloc faster here?** Almost certainly yes, on the evidence in the tree: the pool
runs 15 workers generating/lighting/meshing chunks, each allocating and freeing small
blocks (the `lib.rs:340-343` comment records Windows' heap at 16 % of a chunk's generation
time). mimalloc's per-thread heaps avoid the arena/lock contention. glibc's per-thread
arenas narrow the gap on Linux but do not close it. `system-allocator` exists only for
heaptrack/valgrind.

**The one real cost:** `configure_allocator()` (`crates/horizon-threads/src/lib.rs:362-373`)
sets `mi_option_purge_delay = 0` — "free pages go back to the OS at once". That turns
page frees into `madvise`/`munmap` plus page faults on the next allocation, exactly during
the chunk churn that the pool exists to speed up. It was chosen for RSS (the comment says
a quarter more memory without it). For a speed build:

* test `mi_option_purge_delay = 1000` (mimalloc v3 default) or `-1` (never purge), and
* make the call respect the environment, e.g. skip it when `MIMALLOC_PURGE_DELAY` is set,
  so it can be A/B'd without a rebuild (mimalloc reads the env at process init, before
  `main`, and `configure_allocator` currently overwrites it).

Other mimalloc options worth one A/B each: `mi_option_reserve_huge_os_pages = 1`
(2 MiB pages reduce TLB misses on the chunk/mesh working set; costs a little RSS and a
few ms at first touch), `mi_option_eager_commit = 1` (default on 64-bit),
`mi_option_arena_eager_commit = 2` (default).

---

## 3. Recommended profile set (exact diff)

Runtime is what matters; build time is a stated cost, not a constraint.

```diff
 [profile.lite]
 inherits = "release"
 lto = "fat"
 codegen-units = 1
 panic = "abort"
 debug = 0
 incremental = false
+debug-assertions = false
+overflow-checks = false
+# keep the symbol table: crash reports symbolize through it (there is no DWARF in
+# release). "symbols" would shrink the binary by ~24 MB and lose every stack name.
+strip = "none"
+
+# Package overrides are per-profile; repeat them so the mod-API codegen (syn over every
+# file of game/, ~1.5 s optimised vs ~6 s not) does not regress the build.
+[profile.lite.package.horizon-mod-api-gen]
+opt-level = 3
+[profile.lite.package.syn]
+opt-level = 3
+[profile.lite.package.proc-macro2]
+opt-level = 3
+
+# Instrumented PGO build. Thin LTO halves the build; the counts are identical and
+# survive the fat-LTO link of the final build.
+[profile.lite-pgo]
+inherits = "lite"
+lto = "thin"
```

Rationale, in order of payoff:

| Setting | Why | Cost |
|---|---|---|
| `lto = "fat"` | Whole-program inlining/constant-propagation across 30+ crates; thin LTO already at 1 CGU/crate gets most of it, fat gets the rest (1–4 %). | Link time 2–5×; several GB RAM at link. |
| `codegen-units = 1` | Already release; keeps every crate one LLVM module so LTO sees whole functions. | Build time. |
| `panic = "abort"` | Removes landing pads and unwind edges (0.3–1.5 %), drops `.eh_frame` 5.5 MB and `.gcc_except_table` 2.8 MB. | Loses the `catch_unwind` recoveries in §1.2; abort exit code ≠ 101. |
| `debug = 0`, `debug-assertions = false` | Already the release defaults; stated explicitly so a future `debug = 1` experiment does not silently ship. | — |
| `strip = "none"` | 19.7 MB `.strtab` + 4.1 MB `.symtab` stay, so `crash::install`'s `Backtrace::force_capture` still prints function names. | Binary size. |
| `lite-pgo` (`lto="thin"`) | Training build. | — |

Not recommended: `[profile.lite.package."*"]` (release already optimises all non-build
deps at 3); `build-override` (build time only); `strip = "symbols"` unless a size-focused
artifact is wanted (it costs every name in a crash report).

---

## 4. Flags: what to put in `RUSTFLAGS`

Everything below is stable on 1.95/1.99. No `-Z` flag is needed, and the useful ones
(`-Zbuild-std`, `-Zlocation-detail=none`, `-Zfmt-debug=none`) require nightly — do not
chase them; `location-detail=none` only saves ~1–2 MB of panic-location strings.

```sh
# Shipping build, portable to any x86-64-v3 CPU (AVX2/FMA/BMI2/POPCNT, Haswell 2013+):
RUSTFLAGS="-C target-cpu=x86-64-v3"

# Local "fastest on this box" build:
RUSTFLAGS="-C target-cpu=native"

# Apple silicon / ARM: -C target-cpu=native (or apple-m1/apple-m2 for a shippable build).

# Optional, Linux/ELF, ~0.3–1 % (removes GOT indirection and ~114k startup relocations):
RUSTFLAGS="$RUSTFLAGS -C relocation-model=static -C link-arg=-no-pie"

# Optional, size/i-cache only; lld folds identical functions:
RUSTFLAGS="$RUSTFLAGS -C link-arg=-Wl,--icf=safe"

# Only for a BOLT input binary:
RUSTFLAGS="$RUSTFLAGS -C link-arg=-Wl,--emit-relocs -C force-frame-pointers=yes"
```

Notes:

* `target-cpu` is a `rustflags` setting, not a profile setting; Cargo has no stable
  per-profile rustflags. Either export it (as `scripts/build-speed.sh` does) or add a
  `--config` file; do **not** put it in a committed `.cargo/config.toml`, or every `dev`
  build inherits it and every rebuild after a CPU change is a full recompile.
* `-C target-cpu` does not reach the C build of mimalloc; add
  `CFLAGS_x86_64_unknown_linux_gnu="-O3 -march=x86-64-v3"` if you care (tiny).
* `-C force-frame-pointers=yes` costs ~1 %; use it only on the profiling/BOLT input.
* `relocation-model=static` gives up ASLR. For a personal build, fine; for a shipped
  binary, hardening regressions and some distro policies apply.
* `--icf=safe` is lld syntax and is only safe if nothing compares function addresses for
  identity; the codebase uses `fn` pointers (e.g. `LINE_HOOK`, native hooks) but compares
  through `OnceLock::set`, not by address. Verify with a smoke run.

---

## 5. PGO recipe (reproducible)

PGO is the single biggest runtime lever and the workload is unusually convenient: the
game ships its own deterministic benchmark.

**Prerequisites.** Prepared resources (`.local/horizon-client/26.3` via
`horizon-prepare`), a GPU (or Xvfb), and a quiet machine.

```sh
cd /home/solenopsisbot/coding/mc/horizon-lite
PROF=/tmp/opencode/horizon/pgo
rm -rf "$PROF" && mkdir -p "$PROF"
CPU="-C target-cpu=x86-64-v3"          # same value in both passes

# 1) instrumented build (thin LTO: ~2x faster than fat, same counts)
RUSTFLAGS="$CPU -Cprofile-generate=$PROF" \
  CARGO_INCREMENTAL=0 \
  cargo build --profile lite-pgo -p horizon-client

# 2) training runs — all of them, into the same directory
BIN=target/lite-pgo/horizon-client
GAME=/tmp/opencode/horizon/train-game
RES=$PWD/.local/horizon-client/26.3
mkdir -p "$GAME"

# 2a. gameplay: the 4-scene scripted benchmark (worldgen, meshing, entities, physics,
#     rendering, menus). ~3-5 min instrumented.
( cd "$GAME" && HORIZON_HOME="$GAME/home" HORIZON_NO_AUDIO=1 \
  "$OLDPWD/$BIN" --resources "$RES" --game-dir "$GAME" --benchmark standard )

# 2b. startup: one ordinary launch, which the benchmark cannot cover because
#     --benchmark forces synchronous_startup. Stay on the title ~20 s, open a world,
#     fly for ~40 s, then quit through the control socket (clean exit => profraw).
( cd "$GAME" && HORIZON_HOME="$GAME/home" HORIZON_NO_AUDIO=1 \
  "$OLDPWD/$BIN" --resources "$RES" --game-dir "$GAME" --control --world World & )
sleep 60
horizon-ctl quit || kill %1                 # or close the window / SIGTERM (saves, exits)

# 2c. optional: a second benchmark run; more counts, less variance.

# 3) merge with the llvm-profdata that matches rustc, not the distro's
HOST=$(rustc -vV | sed -n 's/^host: //p')
LLVM_PROFDATA=$(rustc --print sysroot)/lib/rustlib/$HOST/bin/llvm-profdata
"$LLVM_PROFDATA" merge -o "$PROF/merged.profdata" "$PROF"

# 4) final build
RUSTFLAGS="$CPU -Cprofile-use=$PROF/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
  CARGO_INCREMENTAL=0 \
  cargo build --profile lite -p horizon-client
```

Rules that matter:

* Use **absolute** paths for `-Cprofile-generate/use`; relative paths resolve against the
  invoking CWD, which is not stable across `cargo` and the game.
* The process must exit normally (the benchmark's `quit`, a window close, or SIGTERM — the
  game saves and returns). `panic=abort` or a kill loses that run's `.profraw`.
* `-Cprofile-use` matches counts by function; it is robust to the thin→fat LTO change and
  to recompiles, and `-pgo-warn-missing-function` lists what was not covered (grow the
  training set if hot code appears there).
* Keep the profile with the release artifact (e.g. `packaging/pgo/merged.profdata` +
  the commit hash) so a rebuild is reproducible. PGO is machine-*independent* but
  workload-dependent; retrain when the benchmark or the renderer changes materially.
* `cargo-pgo` (external) automates the same steps; nothing in the repo needs it.

Expected: **5–15 %** on CPU-bound frames and chunk generation, the usual range for a
branch-heavy interpreter-shaped codebase like this one (enum dispatch, per-block state
checks, per-section bookkeeping). Verify with §11.

---

## 6. BOLT recipe (Linux, optional, after PGO)

```sh
# Build the BOLT input (frame pointers + relocations; ~1 % slower than the PGO binary).
RUSTFLAGS="$CPU -Cprofile-use=$PROF/merged.profdata \
  -C link-arg=-Wl,--emit-relocs -C force-frame-pointers=yes" \
  cargo build --profile lite -p horizon-client

# Profile the same binary on the same workload.
perf record -e cycles:u -j any,u -o /tmp/opencode/horizon/bolt/perf.data -- \
  target/lite/horizon-client --resources "$RES" --game-dir "$GAME" --benchmark standard

# Reorder.
llvm-bolt target/lite/horizon-client -o target/lite/horizon-client.bolt \
  -data=/tmp/opencode/horizon/bolt/perf.data \
  -reorder-blocks=ext-tsp -reorder-functions=hfsort+ \
  -split-functions -split-all-cold -dyno-stats
```

Caveats: `llvm-bolt` for LLVM 23 is not installed here (`apt install llvm-23` or build
from llvm-project); it must match the compiler's major version. BOLT does not understand
Rust's `.llvm.*` sections beyond block/function layout, so gains are 3–8 % on branchy code,
not the 20 % some C++ projects see. Keep the un-BOLTed binary for crash reports unless you
also keep the `.bolt` address map.

---

## 7. wgpu backends and naga features: runtime or just bytes?

**Backends.** `crates/horizon-client-render/Cargo.toml:59-70` enables `vulkan`, `metal`,
`wgsl`, `naga-ir` unconditionally; `dx12` on Windows; `gles` on non-macOS.
`backend_order()` (`gfx.rs:1976-1997`) tries only *one* backend per attempt, and
`Instance::new()` with `Backends::VULKAN` enumerates only Vulkan ICDs. A compiled-in but
unrequested backend is dead code: no instance, no enumeration, no adapter.

* Dropping `gles` on a Linux build: **0 % runtime** when Vulkan works; saves text and
  removes the OpenGL fallback for machines without Vulkan (the last-resort path in
  `device_search`). Only do it for a build that is explicitly Vulkan-only.
* Dropping `dx12`: same, Windows-only, and it removes the fallback the launcher selects
  after a Vulkan driver crash (`#746`).
* Keeping both costs I-cache nothing at runtime (never called), only binary size and
  `cargo check` time.

**naga.** `horizon-client` and `horizon-client-render` enable `hlsl-out` in their normal
dependency (not only dev-deps), and `horizon-shader-api` (a runtime dep of both) enables
`wgsl-in, spv-out, msl-out, hlsl-out`. These exist for pack translation/checking and for
the DX12 shader path. With no shader pack and Vulkan, `hlsl-out`/`msl-out`/`glsl-out` are
never called. Removing them from the *normal* dependency set is possible only if no pack
is ever loaded (Lite's fence cuts packs eventually), and it is a size/build win, not a
frame win. Keep them until the pack cut lands.

**Verdict:** backend/naga pruning is a binary-size and build-time decision. Do not expect
FPS from it.

The one backend-adjacent runtime item that *is* worth changing:
`wgpu::MemoryHints::MemoryUsage` at `gfx.rs:2384` explicitly "favors memory usage over
performance" (it was chosen to cut VRAM reservations from ~1.3 GiB to ~0.5 GiB).
`MemoryHints::Performance` is wgpu's default and may reduce device-memory allocation
stalls during chunk uploads. A/B it; VRAM goes up.

---

## 8. Startup: every step before the first frame, ranked

Path for an ordinary launch (`game.rs:17677` → `run_loading` → `Loading::resumed`):

1. `main` → `entry::main` → allocator, `telemetry::mark_start`, `spans::startup::init`,
   `trace::start_from_env` (`entry.rs:15-23`).
2. args parse, `--home`/`--player-dir`, `logging::init` (`logging.rs:539`), first log line,
   `crash::install`, native hook installs, open-file limit (`entry.rs:24-261`).
3. `run_with` (`game.rs:17555`): `Options::read`, dedicated preflight, ~12 `OnceLock`
   posts, `put_helpers_behind`, `favour_current`, stop signals, telemetry consent,
   `missing_resources`, `mods::register_*`, `Settings::load`, `startedCleanly=false` +
   `Settings::save`, `narrator::init`, `Behaviours::set_cache_dir`.
4. `run_loading` (`game.rs:17491`): spawn `resource-loader` thread, `StartupMenu::new`,
   `HudAtlas::boot()` (4 MB + font, `hud.rs:1003`).
5. `EventLoop::new` + `create_window` + icon (`loading_screen.rs:88-124`).
6. `loading_renderer` → `Renderer::new` (`loading_window.rs:104-131`, `gfx.rs:2592`):
   Vulkan instance → adapter → device → surface config → **74 shader modules + 82
   pipelines** → textures.
7. First `renderer.render(&loading_frame)` → `present`.

The loader thread (step 4) runs in parallel: pack root scan, `load_core` (assets,
registry, models, sprites, biomes, collision), UI atlas + panorama, then rest tables.

| # | Work | Est. ms (warm cache, Vulkan) | Before first frame | Evidence | Recommendation / edit point |
|---|---|---|---|---|---|
| 1 | `Renderer::new`: naga WGSL→IR→SPIR-V for 74 modules, 82 driver pipelines | **250–900** (cold driver cache 1–3 s; DX12: **2.6 s FXC / ~1 s DXC**, claimed) | **yes** | 94 `include_str!(*.wgsl)`, 74 `create_shader_module`, 69 render + 13 compute pipelines; `third_party/wgpu-hal/src/dx12/disk_cache.rs:1-10` | **Highest value.** (a) A HUD/panorama-only boot renderer (`Renderer::new` flag) so the loading screen appears after ~5 % of the pipelines; build the rest on a worker during loading. High effort (~struct split, `Option` fields). (b) Lower effort, no refactor: a persisted `wgpu::PipelineCache` (§9). |
| 2 | Vulkan instance + adapter + `vkCreateDevice` + `surface.configure` | 40–150 | yes | `gfx.rs:2294-2400`; `horizon_hdr::open_vulkan_device` adds one extension query | Cannot be removed; cache nothing across processes. Keep the second/third renderer on the *same* device (already done, `gfx.rs:2613-2646`). |
| 3 | winit event loop + window + surface + icon | 15–60 | yes | `loading_screen.rs:88-124` | Nothing to do; `with_visible(false)` + show after the first present only removes the white flash. |
| 4 | `HudAtlas::boot()` (1024² RGBA, font parse) | 5–30 | yes | `hud.rs:1003` | Optional: 512² boot atlas (-3 MB, a few ms). |
| 5 | `logging::init`: open+lock `latest.log`, **read and gzip the previous log**, roll archives | 0–300 (log-size dependent) | yes | `logging.rs:224-268` (`roll` → `archive` → `GzEncoder` + `sync_all`) | Move rollover/gzip to the writer thread (it already exists, `logging.rs:288`) or do it after the first frame. ~20 LOC, no behaviour change. |
| 6 | `Settings::load` + `Settings::save` (5 files: options.txt, horizon, controller, extras, mods) | 2–15 | yes | `game.rs:17646-17660`, `settings.rs:678-691` | Write the `startedCleanly=false` marker after the first frame (or on a worker); correctness impact: a crash between frame 0 and the write would not reset fullscreen next start. |
| 7 | options/hook/crash/consent/narrator thread | 2–10 | yes | `entry.rs`, `game.rs:17602-17664` | `narrator::init` and `debug_keys::warm_debug_cpu` (`window_handler.rs:198`) spawn threads at start; make them lazy. Micro. |
| 8 | (parallel) UI bundle: `HudAtlas::build_over_with_image` + 6 panorama faces | 100–400 | no (title) | `resource_tables.rs:93-117`, `resource_load.rs:349-397` | Already parallel with `load_core`. |
| 9 | (parallel) `load_core`: assets, registry, model library, sprites, biomes, collision, facts | 300–900 | no | `resource_load.rs:150-320` | Already the most parallel part; `ParsedModels` runs beside `Assets::load`; `horizon-data.bin` (`prepared_files`) already caches JSON. |
| 10 | Title renderer rebuild (`set_ui`): new atlas/panorama upload, pipelines reused | 30–120 | no | `loading_screen.rs:197-232`, `gfx/reuse.rs` | Fine; only the texture re-upload is paid. |
| 11 | Handoff: world renderer (32 MB block sprites + PBR mips) + `Game::new` + `Audio::with_device` | 100–400 | no | `loading_window.rs:26-99`, `loading_screen.rs:294-383` | Already on the main thread after the title is usable; leave. |

Two structural notes:

* **The loading screen is gated on every pipeline**, even though it draws one atlas and a
  panorama. That is the whole of item 1 before first paint. Everything else in the list is
  either parallel or small.
* **`Reuse` formats every descriptor with `{:?}`** (`gfx/reuse.rs:118-135`), which for a
  `ShaderModuleDescriptor` includes the full WGSL source. On the *first* renderer
  (`previous == None`) that cache is freshly created, so ~272 KB of shader text plus every
  pipeline descriptor is formatted into `String` keys that the *next* renderer will
  copy — useful then, pure cost now. Guard with `if previous.is_some()`, or key on a hash.

---

## 9. Shader/pipeline caching that is missing

* **In-memory:** `Reuse` (`gfx/reuse.rs`) keeps modules/layouts/pipelines per device across
  the three renderer builds. Correct and effective.
* **DX12:** a persisted FXC bytecode cache exists (`third_party/wgpu-hal/src/dx12/disk_cache.rs`,
  wired at `gfx.rs:1925-1931`, file `<home>/cache/dx12-shaders.bin`, FNV-1a key over
  compiler+stage+entry+HLSL). This is why Windows second starts are ~1–2.5 s faster.
* **Vulkan:** **nothing.** The driver's own shader cache (Mesa `~/.cache/mesa_shader_cache`,
  NVIDIA's `~/.nv/GLCache` equivalents) hides the `vkCreateGraphicsPipelines` cost after a
  first run, but naga still parses and validates all 94 WGSL sources and emits SPIR-V on
  every start.
* **Metal:** nothing persisted.

Two concrete additions, in order of effort:

1. **`wgpu::PipelineCache`** (Vulkan and Metal both implement it; `wgpu-hal` exposes
   `pipeline_cache_validation_key` so stale data is discarded safely):
   ```rust
   let cache = unsafe { device.create_pipeline_cache(&wgpu::PipelineCacheDescriptor {
       label: Some("Horizon pipelines"),
       data: std::fs::read(path).ok().as_deref(),
       fallback: true,
   }) };
   // ... pass `cache: Some(&cache)` in every RenderPipelineDescriptor/ComputePipelineDescriptor
   // ... `fs::write(path, cache.get_data())` on clean exit
   ```
   ~40–60 LOC touching every pipeline descriptor (they all already have `cache: None`).
   Saves the driver compile on starts 2..n; naga still runs.
2. **Precompiled SPIR-V for embedded shaders** (Vulkan-only build): a `xtask` step runs
   naga's WGSL frontend + SPIR-V writer over the 32 `.wgsl` files at build time, and
   `Renderer` uses `ShaderSource::SpirV` (wgpu `spirv` feature) instead of `Wgsl`.
   Saves the naga front-end+validation+SPIR-V generation each start (~100–300 ms
   estimated). Requires a per-backend build (DX12 needs naga IR for HLSL, Metal for MSL),
   so it belongs in a "Vulkan speed" profile, not the default.

---

## 10. Overheads still switched on in release

| Item | Where | Cost | Recommendation |
|---|---|---|---|
| wgpu validation | `gfx.rs:1914-1943` | **off** (release `InstanceFlags` empty; indirect-call validation additionally removed unless DX12, per `gfx.rs:1932`) | none needed |
| `debug_assertions` | — | off; 6 `cfg!(debug_assertions)` sites all const-fold | none |
| `spans` (`HORIZON_SPIKES`/`TRACE`) | `spans.rs:59-98` | off; 1 relaxed atomic + 1 TLS lookup per span | none |
| `startup` trace | `spans.rs:556` | one relaxed load per *startup* step | none |
| **GPU frame timer** | `gfx/timing.rs`, created unconditionally at `gfx.rs:2781` when `TIMESTAMP_QUERY` exists | 2 timestamp writes + query resolve + 16-byte copy + `map_async`/`unmap` + `device.poll` **every frame** (`gfx.rs:11565-11568`) | create it only when F3 stats, `--benchmark`'s `gpu-passes`, or perf-consent recording is on; ~0.3–1.5 % frame CPU |
| telemetry `Session::frame` | `telemetry.rs:257` | one histogram increment + `is_finite` check per frame | leave |
| `MemoryHints::MemoryUsage` | `gfx.rs:2384` | favours VRAM over speed | A/B `Performance` |
| mimalloc `purge_delay=0` | `horizon-threads/src/lib.rs:362-373` | syscall + page-fault churn under allocation churn | A/B 1000 / -1 |
| log level | `logging.rs:583` | `LevelFilter::Info` always; a `log::info!` in a hot path would format + channel-send | audit any per-frame `info!` (none found in `render`) |
| generated mod API | `target/*/build/horizon-client-*/out/mod_api_generated.rs` (8 284 lines) | empty dispatch = pointer-range check per call; code size 832 KB of source | add `if mods.is_empty() { return; }` to the generator if profiling shows `dispatch_*`; low value |

---

## 11. Threading

* One shared pool for *all* background work (`horizon-threads/src/jobs.rs`), sized
  `available_parallelism() - 1` (`lib.rs:24-48`), overridable with
  `HORIZON_WORKER_THREADS` (the count) and `HORIZON_JOB_THREADS` (the pool), and by
  Graphics → Worker threads (`jobs::configure`, `resource_load.rs:340`).
* On 16 logical CPUs that is 15 workers **plus** the render thread, the integrated server
  thread, the render-submit thread, the log writer, and the streaming/preload threads —
  17–20 runnable threads for 16 CPUs. `put_helpers_behind` nices workers to +10 on Linux
  (`lib.rs:179-197`) and `favour_current` raises the render thread on Windows/macOS only;
  on Linux a worker holding a core is not preempted by niceness alone.
  **Try `HORIZON_WORKER_THREADS=12`** (and 10/14) on the benchmark; p99 frames during
  terrain load are the metric. This is an empirical knob, not a build change.
* Single-thread bottlenecks, in order: the render thread (records and encodes the entire
  frame; only finish/submit/present go to the submit thread), the integrated server thread
  (all ticks), and `Renderer::new` (all pipeline creation). The resource load is already
  split across 6–8 scoped threads plus the rest worker.

---

## 12. Ranked expected gains

| Rank | Change | Expected | Confidence | Notes |
|---|---|---|---|---|
| 1 | **PGO** (§5) | **5–15 %** CPU-bound FPS; 5–15 % chunk gen/mesh throughput | medium-high | The most branch-heavy code (block states, enum dispatch) is exactly what PGO fixes. |
| 2 | **BOLT** (§6) | 3–8 % | medium | Needs `llvm-bolt` 23 + `perf`; Linux only. |
| 3 | **`-C target-cpu=x86-64-v3`/`native`** | 2–8 % overall; more in noise/meshing/atlas math | medium | Zen 2 gains `avx2/fma/bmi2/lzcnt/popcnt/movbe`; no fast-math, so float results are unchanged. |
| 4 | **`lto = "fat"`** over thin | 1–4 % | medium | Costs link time/RAM. |
| 5 | **mimalloc `purge_delay` 0 → 1000/-1** | 1–5 % in streaming/churn scenes | medium-low | Costs RSS (the code comment says up to 25 %). |
| 6 | **GPU timer off unless read** | 0.3–1.5 % frame CPU | medium | Also removes one GPU resolve/copy per frame. |
| 7 | **`panic = "abort"`** | 0.3–1.5 % | medium-low | Behaviour cost in §1.2. |
| 8 | **`MemoryHints::Performance`** | 0–2 % | low | VRAM up ~2–3× on reserved blocks. |
| 9 | **`relocation-model=static` + `--icf=safe`** | 0.3–1 % | low | ASLR lost. |
| 10 | Backend/naga pruning | **0 %** runtime | high | Size/build only. |

Startup (time to first frame), ranked by what to do first:

1. HUD-only boot renderer, full pipelines built during loading — **250–900 ms** (high effort).
2. Persisted `wgpu::PipelineCache` (Vulkan/Metal) — **100–600 ms** on starts 2..n (medium).
3. Precompiled SPIR-V for embedded WGSL — **100–300 ms** (medium-high effort, Vulkan only).
4. Log rollover on the writer thread — **0–300 ms** (low effort).
5. Skip the startup `options.txt` write until after frame 0 — **2–15 ms** (low).
6. Lazy narrator/debug-cpu threads, smaller boot atlas — **5–30 ms** (trivial).

---

## 13. Risks

* **Portability.** `target-cpu=native` binaries crash with `SIGILL` on older CPUs; ship
  `x86-64-v3` (2013+) or build two variants (v2/v3) and pick by CPUID in the launcher.
  `relocation-model=static` breaks PIE/ASLR. PGO profiles are workload-specific: retrain
  when the benchmark or renderer changes, or keep the profile generation in CI.
* **Debuggability.** `panic=abort` removes the recoveries in §1.2 and changes exit codes
  (`SIGABRT` instead of 101); `strip="none"` keeps crash stacks but the binary is 108 MB
  in `fast` (61 MB `.text`, 19.7 MB `.strtab`, 4.1 MB `.symtab`, 5.5 MB `.eh_frame`).
  `target-cpu` and PGO make symbol-level debugging of a crash report harder to reproduce.
* **Build time.** `lto="fat"` + `cgu=1` is the slowest possible link (expect 2–5× the
  release link; the tree's Linux cold `fast` build is 184.7 s per `docs/build-times.md`);
  PGO doubles it once, plus the training run (5–10 min) and an optional BOLT pass.
* **Correctness.** `panic=abort` changes glue behaviour; `--icf=safe` can fold functions
  whose address is compared; `MemoryHints::Performance` and `purge_delay` trade VRAM/RSS
  for speed. Each needs the smoke run (`--world-frames 600 --smoke-report`) and the
  benchmark before shipping.
* **The in-progress script** has a dangling doc reference and an over-broad PGO workload;
  fix it before anyone trusts a "PGO build" number from it.

---

## 14. How to verify (acceptance)

```sh
# Startup, per-step: the game already logs every stage.
HORIZON_STARTUP_TRACE=/tmp/opencode/horizon/startup.json ./target/lite/horizon-client ...
# grep the log for: "loading screen shown after", "UI bundle ready after",
# "core-ready after", "rest-ready after", "world renderer ready after",
# "startup handoff", "first frame after".

# Runtime: same world, same machine, 5 runs, medians. The benchmark is scripted.
./target/lite/horizon-client --benchmark standard --game-dir /tmp/.../bench
# compare startup.title_ms, chunks.*.load_ms, frame p50/p99 in the report.

# Cold-start A/B: drop the page cache (or use a fresh binary path) and hyperfine
# `--prepare 'sync'`; a smaller/stripped binary shows up here, not in FPS.
```

The tree's `tools/` has no `startup_trace.py` (the doc comment in `spans.rs:459` is stale);
Perfetto opens the file directly.

---

## Appendix — index of edit points

| File:line | What |
|---|---|
| `Cargo.toml:93-115` | `release`/`fast`/`lite` profiles |
| `scripts/build-speed.sh` | existing native/PGO build; see §1.2 for fixes |
| `crates/horizon-client/src/main.rs:4-9` | global allocator selection |
| `crates/horizon-threads/src/lib.rs:340-373` | `Allocator`, `PURGE_DELAY`, `configure_allocator` |
| `crates/horizon-threads/src/lib.rs:24-48` | worker count / `default_workers` |
| `crates/horizon-threads/src/jobs.rs:168-196, 420-504` | pool creation, per-job `catch_unwind` |
| `crates/horizon-client/src/entry.rs:15-23, 57-63` | allocator, startup spans, log init |
| `crates/horizon-client/src/game.rs:17491-17555` | `run_loading` |
| `crates/horizon-client/src/game.rs:17646-17660` | `Settings::load` + `startedCleanly` save |
| `crates/horizon-client/src/game/loading_screen.rs:88-179` | window + boot renderer (first frame) |
| `crates/horizon-client/src/game/loading_screen.rs:197-232` | title-artwork renderer rebuild |
| `crates/horizon-client/src/game/loading_window.rs:104-164` | `loading_renderer` |
| `crates/horizon-client/src/game/resource_load.rs:326-597` | parallel resource load, handoff |
| `crates/horizon-client-render/src/gfx.rs:1914-1943` | instance flags, DX12 shader cache |
| `crates/horizon-client-render/src/gfx.rs:2294-2400` | device, features, `MemoryHints` |
| `crates/horizon-client-render/src/gfx.rs:2592-2800` | `Renderer::new`, `Reuse`, `GpuTimer` |
| `crates/horizon-client-render/src/gfx/timing.rs:135-215` | per-frame timestamps |
| `crates/horizon-client-render/src/gfx/reuse.rs:118-135` | descriptor-string cache keys |
| `crates/horizon-client-render/src/logging.rs:202-268, 539-585` | log rollover/gzip, `init` |
| `crates/horizon-client-render/src/settings.rs:233, 678-691` | defaults (`vsync`, `max_fps`), `save` |
| `crates/horizon-client-render/src/crash.rs:77-97` | `crash::contain` (lost under `panic=abort`) |
| `crates/horizon-client/src/game/window_handler.rs:198` | `warm_debug_cpu` thread |
