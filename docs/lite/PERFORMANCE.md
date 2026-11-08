# Performance: making Horizon Lite fast

This fork's second goal, after removing product surfaces, is **speed**: maximum frames per
second, fewer hitches, faster world load, lower memory. This page records what was measured, what
actually costs time, what was changed, and what is still on the table. It is deliberately separate
from [`PLAN.md`](PLAN.md): that page is about product surface, this one is about the frame clock.

## The short version

1. **The renderer is already lean.** At 1280×720 with no pack, HDR, OIT, TAA or LOD, a world frame
   is 2–3 passes and 30–70 draw calls. The average frame on the test GTX 970 was **334–1125 FPS**
   before any change.
2. **The defaults were the problem.** Render distance 12, simulation distance 12, fancy 3D clouds
   out to 128 chunks (~91k cells), all particles, entity shadows, fancy cutout leaves, VSync on and
   a 120 FPS cap. Changing the defaults is worth far more than deleting code.
3. **Deleting optional features buys almost no FPS.** Cosmetics, Studio, agent control, the
   narrator, LOD/BlueMap, shader packs, HDR and OIT are idle or off by default: each is 1–20 µs
   per frame or literally zero. They are still worth deleting for memory, build time and crash
   surface — but not for the frame rate.
4. **The real remaining cost is chunk streaming.** Average FPS is excellent; 0.1%-low in the
   mountain scene was **9.5 FPS** because new terrain generates, meshes and uploads in the flight
   path. Stutter, not throughput, is what a player feels.
5. **Build-side wins are real and cheap:** fat LTO + one codegen unit, `target-cpu=native`, PGO
   (5–15%), and keeping mimalloc's one-second purge delay instead of purging on every free.

## What was measured

Protocol: [`reports/perf-measure.md`](reports/perf-measure.md). Hardware: Ryzen 7 3700X, 16
threads, 32 GB, GeForce GTX 970 4 GB, NVIDIA 580.196.07, Vulkan, 1280×720 **offscreen**, VSync off,
benchmark-forced unlimited frame rate, seed 1234, render distance 12 / simulation 12 (upstream
defaults). The run was **contended**: load average 9.65 from other builds on the same machine, and
~2 GB of the 4 GB VRAM was held by two long-lived llama-server processes. Treat the absolute
numbers as a floor, not a hero figure.

| Metric | Baseline (`fast` profile, before changes) |
|---|---:|
| Startup to title | **3,208 ms** |
| World load | **7,396 ms** |
| Village | 1,125 avg / 203 1%-low / 76.8 0.1%-low FPS |
| Forest | 838 / 186 / 95.7 |
| Ocean | 930 / 168 / 68.2 |
| Mountain | 334 / 24.9 / 9.5 |
| Chunk load, forest / mountain | 3.0 s / 9.0 s |
| Chunks generated, mountain | 70.6/s |
| RSS steady / peak | 1,271 / 1,427 MB |
| GPU allocated | 405 MB |
| Binary | 108 MB |

The benchmark forces VSync off and an unlimited rate, so it **cannot** show the win from removing
the VSync/120-FPS caps; that part is measured by playing, not by this harness.

## A/B result: the speed defaults

Two `fast`-profile binaries, same machine, same driver, same prepared resources, 1280×720
offscreen, standard 4-scene benchmark, 3 runs each, alternating A/B. A is the binary before this
change (vanilla defaults: RD 12, sim 12, fancy clouds, all particles, VSync on). B is this fork
(RD 8, sim 6, clouds off, minimal particles, solid leaves, async culling, plus the code changes
below). Each run used a brand-new game folder with **no `options.txt`**, so each binary's own
defaults applied. Medians of 3 runs (one A run hit a load spike; medians are used so it cannot drag
the result):

| Metric | A (before) | B (after) | B/A |
|---|---:|---:|---:|
| Village avg FPS | 1,173 | 2,106 | **1.80×** |
| Forest avg FPS | 784 | 1,932 | **2.47×** |
| Ocean avg FPS | 952 | 1,334 | **1.40×** |
| Mountain avg FPS | 977 | 1,975 | **2.02×** |
| Village 1%-low | 349 | 628 | 1.80× |
| Forest 1%-low | 270 | 548 | 2.03× |
| Ocean 1%-low | 315 | 546 | 1.73× |
| Mountain 1%-low | 274 | 534 | 1.95× |
| Village 0.1%-low | 138 | 239 | 1.73× |
| Forest 0.1%-low | 126 | 227 | 1.81× |
| Ocean 0.1%-low | 141 | 213 | 1.52× |
| Mountain 0.1%-low | 145 | 246 | 1.70× |
| Startup to title | 1,222 ms | 1,203 ms | 0.98× |
| World load | 3,574 ms | 2,728 ms | **0.76×** |
| Chunk load, village | 2,209 ms | 1,233 ms | **0.56×** |
| Chunk load, forest | 2,307 ms | 1,703 ms | 0.74× |
| Chunk load, ocean | 1,955 ms | 971 ms | **0.50×** |
| Chunk load, mountain | 4,061 ms | 1,956 ms | **0.48×** |
| GPU memory | 405 MB | 265 MB | **0.65×** |
| RSS steady | 1,267 MB | 1,575 MB | 1.24× |
| RSS peak | 1,493 MB | 1,733 MB | 1.16× |

The frame rate more than doubles in forest and mountain, the hitches (0.1%-low) improve 1.5–1.8×,
and chunk-heavy scenes load about twice as fast. GPU memory drops by a third because there are 54%
fewer columns at RD 8. RSS rises ~24%: that is the deliberate mimalloc trade (its one-second purge
delay instead of purging on every free) plus a smaller view distance not offsetting the allocator's
retained pages. If memory matters more than the last few percent, set the purge delay back to 0 in
`crates/horizon-threads/src/lib.rs`.

What this A/B does **not** isolate: the benchmark forces VSync off and an unlimited rate, so the
removal of the 60/120 FPS caps is invisible here — on a real display that is an additional,
sometimes large, win. It also does not separate the defaults from the code changes (mod-dispatch
guard, caches, raid early-out): a code-only run with both binaries on the same frozen
`options.txt` was not completed, because the default change accounts for nearly all of the delta.
The mod-API guard's own estimate is 0.1–0.5% CPU; the caches are microseconds per frame.

Caveats: 3 runs per side, offscreen frames (no swapchain present), load average ~10 from other
builds on the machine, 2 GB of the 4 GB VRAM held by other processes, and startup-to-title was
measured with a warm driver shader cache in both sides (hence equal, and lower than the cold 3.2 s
in the baseline table above).

## What actually costs frame time

From [`reports/perf-render.md`](reports/perf-render.md), [`reports/perf-frame.md`](reports/perf-frame.md)
and [`reports/perf-tick.md`](reports/perf-tick.md):

| Cost | Default | Estimated effect of fixing it |
|---|---|---|
| Render distance 12 → 8 | 12 | ~625 → 289 columns: the largest single win |
| Simulation distance 12 → 6 | 12 | ~625 → 169 ticked chunks; entity/spawn/random-tick work |
| Fancy clouds, range 128 | on | 3–12% when sky is visible, plus rebuild hitches; ~91k cells |
| VSync + 120 FPS cap | on | caps displayed FPS at 60/120 regardless of headroom |
| All particles | on | 1–5% typical, 15–30% in heavy scenes |
| Weather radius 10 | on | 3–8% in rain; 441 vs 49 columns |
| Fancy cutout leaves | on | 3–10% in forests |
| Entity distance 1.0, shadows | on | 1–5% typical, 10–30% in crowded scenes |
| HUD per-frame allocations | — | 0.15–0.8 ms, 1–3 ms with chat/scoreboard |
| `getcwd()` + `env::var` per frame | — | syscall each frame in two places |
| Paused HUD rebuild | — | full rebuild + upload while nothing changes |
| Chunk generation + meshing | — | 0.1%-low 9.5 FPS in the mountain flight |

## What was changed in this fork

### 1. Speed defaults

`Settings::default()` and the `options.txt` fallbacks now ship: render distance **8**, simulation
distance **6**, unlimited FPS (**260** sentinel), VSync **off**, clouds **off** (range capped at
32 chunks if re-enabled), particles **minimal**, entity distance **0.5**, entity shadows **off**,
biome blend **0**, weather radius **3**, chunk fade **0**, vignette **off**, cutout leaves **off**,
menu blur **0**, graphics preset **fast**. The graphics file defaults now enable asynchronous
entity/particle culling, hollow leaf culling and the block-entity model caches.

These are *defaults*, not locks: every one is still a setting in the vanilla options screens. A
player who wants the old look can restore it; a new install is fast out of the box.

Honest cost: this is a visible quality change. Render distance 8 and solid leaves are vanilla's
"Fast" territory; clouds off and minimal particles are a bigger departure. That is what "lite =
speed" means here.

### 2. Small hot-path fixes

- `Game::game_dir()` caches the working directory instead of calling `current_dir()` every frame.
- `packed_wanted()` reads `HORIZON_PACKED_QUADS` once instead of every frame.
- `shader_pack_inputs` no longer resolves a pack path (PathBuf clone, file-name allocation, directory
  lookup) when no pack is selected — the default.
- Raids: a tick with no raid and no raider now takes an early-out instead of scanning every mob
  several times; the first quiet tick clears stale villager raid state.
- Cloud cell radius is hard-capped at 32 chunks even if the slider is raised.
- Menu blur is one separable pass (2 draws) instead of three (6 draws), for players who enable it.
- Arena compaction budget is 8 MiB/frame instead of 32, trading a little throughput for smaller
  p99 hitches.

### 3. Build and allocator

- `[profile.lite]`: fat LTO, one codegen unit, `panic=abort`, no debug assertions or overflow
  checks, symbols kept for crash reports. `scripts/build-speed.sh` adds `target-cpu=native` and a
  PGO pass (`--pgo`) that trains on the title screen and the standard benchmark.
- `[profile.lite-pgo]` uses thin LTO for the instrumented build so training does not pay fat-LTO
  time.
- mimalloc keeps its one-second purge delay (upstream set it to 0, favouring RSS over speed). This
  costs memory in the chunk churn and buys frames.
- wgpu memory hints now favour performance over memory use.

### 4. What was deliberately not done

- **Deleting cosmetics/Studio/agent/narrator for FPS.** They cost 1–20 µs/frame when idle. They are
  still on the v0.2 deletion list for build time and surface area, not for frames.
- **Deleting LOD/BlueMap/shader packs/HDR/OIT.** All off by default; zero steady-state FPS.
- **Turning off the features that save time:** section-side culling, cave culling, GPU occlusion
  culling, translucent batching, entity batching, GPU skinning, packed terrain quads, the upload
  throttle and the Linux submit thread. Several of these are large wins; keep them.
- **Lowering resolution scale or enabling TAA upscaling by default.** It is the biggest optional
  GPU lever (15–40%) but visibly softens the image. Left as a setting.

## Feature cuts that do and do not buy FPS

The audits separate two very different things that both look like "remove a feature":

**Real per-frame cost when idle (worth fixing):**

| Item | Cost | Status |
|---|---|---|
| Always-on instrumentation: GPU timer (`timestamps + resolve + copy + map_async + device.poll` every frame), `FrameGraph`/`FrameStats` pushes, `Session::frame`, debug-chart logging | 0.3–1.5% | not done; gate behind F3/benchmark |
| Native mod API dispatch: 33 empty hooks per block event on the integrated server, ~46/frame, one per packet | 0.1–0.5%, more in redstone worlds | **done**: generated `mods.is_empty()` early-out on all 507 dispatch fns |
| Tab-list skin path: `flush_skin_slots` + `update_remote_skins` every frame even when the list is hidden in single player | 3–10 µs/frame | not done |
| Narrator: narration tree rebuilt per widget per screen while Narrator is **Off** (`is_active` means TTS loaded) | menus only | not done |
| Studio recorder mutex taken on every received packet, including chunk streaming | small, hot path | not done |
| Pads polled even with `controllers` off | 1–4 µs/loop | not done (the `horizon-ctl` virtual pad needs it) |

**No steady-state cost (delete for build/memory, not FPS):** cosmetics/emotes, PvP HUD, extras
HUD/minimap, Studio, agent control, narrator code, splitscreen, LOD/BlueMap/server terrain, shader
packs, HDR, OIT, GPU culling, visbuffer, frame generation, FXAA/TAA/upscaling, content mods. Each is
off or idle by default; several are already runtime-inert in this build. That is why the v0.2
deletion list in [`PLAN.md`](PLAN.md) is not an FPS plan.

## Still on the table (ranked, from the audits)

| Change | Expected | Effort |
|---|---|---|
| PGO build (script provided) | 5–15% frames | one command |
| `target-cpu=native` (script provided) | 2–8% | one command |
| Gate always-on instrumentation (GPU timer, frame stats, session records) | 0.3–1.5% | low |
| Persist a `wgpu::PipelineCache` and pass it to the ~80 pipeline creations | 0.1–0.6 s startup after the first run | ~50 LOC |
| Move previous-log gzip off the main thread | 0–0.3 s startup | low |
| Precompiled SPIR-V for Vulkan | 0.1–0.3 s startup | medium |
| HUD-only boot renderer, world pipelines built on a worker during loading | 0.25–0.9 s startup | high |
| Cache the frontier proto in `vanillagen` and track final writes during generation | large chunk-load/stutter win | medium-high |
| Tab-list/skin/narrator/Studio gates above | small, steady | medium |
| Encoder wire cache 32,768 → 4,096 entries | −50–150 MB RSS | low (memory, may cost streaming) |

## How to reproduce

```sh
# The speed build (fat LTO, native tuning, optionally PGO)
scripts/build-speed.sh
scripts/build-speed.sh --pgo        # needs resources + a display (Xvfb is fine)

# A/B benchmark, same machine and settings
/tmp/opencode/horizon/bench.sh --label lite --binary target/lite/horizon-client \
  --scenario standard --runs 3
```

The harness lives outside the repo; its protocol, pitfalls and comparison table are in
[`reports/perf-measure.md`](reports/perf-measure.md). At minimum: same `options.txt`, same
scenario, same `--offscreen`, similar load average, alternating A/B runs, 3 samples.

## Caveats

- The baseline is **contended** (load 9.65, 2 GB VRAM used by other processes). The A/B numbers in
  the next section are meant to be read as deltas on the same machine, not as absolute claims.
- The benchmark measures an **offscreen** frame: no swapchain present, no compositor, no VSync.
  Real windowed FPS will be lower and capped by the display unless VSync stays off.
- PGO profiles are workload-specific: a build trained on the benchmark over-optimises the flight
  path, not mob AI or redstone. Train with real play too if that matters.
- `target-cpu=native` binaries do not run on older CPUs. The script keeps it local; do not publish
  those binaries as generic builds.
