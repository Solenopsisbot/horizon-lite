# Horizon Lite — performance measurement protocol

Status: measurement run in progress. Machine: GTX 970 4 GB, Linux, no display
(Xvfb), 31 GB RAM, 16 threads. All measurements are **read-only on the repo**;
scratch lives under `/tmp/opencode/horizon`.

## 1. What `--benchmark standard` actually does

Source: `crates/horizon-client/src/benchmark.rs`, report format
`crates/horizon-bench/src/lib.rs`.

`--benchmark SCENARIO` starts a driver thread inside the game that sends the
same commands `horizon-ctl` would through the game's own command queue
(`crates/horizon-client/src/game/control.rs`), then quits.

Scenarios: `standard` (= village, forest, ocean, mountain), or one of those
names alone. Fixed world: folder `horizon-benchmark` under the **current
working directory** `saves/`, seed **1234**, creative. The folder is deleted and
regenerated at the start of every benchmark; a folder of that name without the
benchmark's marker file is never deleted (the run fails instead).

Sequence:

1. Wait for the title screen with a renderer (`screen == "title"` and
   `renderer != null`), record `startup.title_ms` from process start.
2. Record GPU (name, vendor, driver, backend, device type, VRAM from telemetry),
   storage, display, load average, power source.
3. `replace_world`, `open horizon-benchmark 1234 creative`, wait for the world
   to load; record `startup.world_ms` (also from process start).
4. Per scene (`village`, `forest`, `ocean`, `mountain`), coordinates in
   `benchmark.rs` `SCENES`:
   - `time 6000` (fixed time of day),
   - `tp X Y Z`, then `fly X Y Z X Y Z 0.1 PITCH` (zero-length, holds position
     flying) and `look`, and wait for chunks around the start to be resident,
     nothing queued, counts quiet, and meshing quiet. Record
     `chunks.<scene>.load_ms`, `.meshed_count`, `.generated_count`,
     `.generated_per_s`.
   - Turn on GPU pass timing, `bench 2` (2 s hold), turn it off; record
     `gpu_pass.<scene>.<pass>_ms` (median per pass; skipped on Metal). This 2 s
     is also the scene's settle/warmup.
   - `fly X1 Y1 Z1 X2 Y2 Z2 12.0 PITCH raw`: a constant-speed 12 s flight with
     a fixed start/end/pitch. The reply carries every frame's frame time, CPU
     time and GPU time. Record `fps.<scene>.avg_fps`, `.low_1pct_fps`,
     `.low_01pct_fps`, plus a `Frames` entry with p50/p95/p99/p999/max, CPU and
     GPU p50, and a fixed-edge frame-time histogram.
5. Record conditions (scenario, seed, render distance, simulation distance,
   window size, vsync, fps cap, offscreen, repeats=1, warmup_s=2, backend) and
   `memory.gpu_mb` (wgpu allocator `total_allocated_bytes`), `memory.rss_peak_mb`
   (sampled 4 Hz) and `memory.rss_steady_mb` (median RSS during the four
   flights), `game.binary_bytes`.

Total wall time is roughly `startup + 4 x (load + 2 s + 12 s)`; the flights are
always 48 s, the loads are machine-dependent.

The report is written to `<cwd>/benchmarks/game-<UTC yyyymmddThhmmss>-<scenario>.json`
and the path is printed as `Horizon: benchmark report <path>`. A second copy is
queued for telemetry under `$HORIZON_HOME` if the player consented (irrelevant
in a scratch home).

The benchmark forces, in memory only: **vsync off**, `max_fps = 260`, pause
disabled, mods/dev mods not started, inactivity limit `minimized`. It never
overrides render distance, simulation distance, resolution, graphics preset or
shader pack — those come from `options.txt` / `horizon-graphics.txt` in the game
folder. **Those files are part of the measurement conditions.**

### Required / useful flags

- `--resources PATH` — prepared resources (`horizon-prepare`). Required.
- `--benchmark standard` — the benchmark.
- `--offscreen` — renders into a texture instead of the window. **Use this.**
  A window is still created (needs a display, hence Xvfb).
- `--headless` — **do not use with `--benchmark`**: it means no window and no
  renderer, so the benchmark waits for a renderer at the title until the 600 s
  load limit and fails. Verified twice (debug and fast builds stall right after
  "worldgen data loaded").
- `--render-distance N` — overrides the options.txt distance for the run; leave
  unset and freeze `options.txt` instead (the report records what was used).
- `--game-dir` — does **not** move the benchmark world: `benchmark.rs` uses
  `std::env::current_dir()` for saves and reports. Run with `cwd` = scratch
  game folder.
- Audio: `HORIZON_NO_AUDIO=1` (silences the audio device; audio is still
  initialised). `--headless` would silence it but cannot be used here.

## 2. Scratch environment

```sh
ROOT=/tmp/opencode/horizon
mkdir -p $ROOT/run/{home,game,xdg-data,xdg-config,xdg-cache,xdg-runtime} $ROOT/reports
chmod 700 $ROOT/run/xdg-runtime
cd $ROOT/run/game
HORIZON_HOME=$ROOT/run/home \
XDG_DATA_HOME=$ROOT/run/xdg-data XDG_CONFIG_HOME=$ROOT/run/xdg-config \
XDG_CACHE_HOME=$ROOT/run/xdg-cache XDG_RUNTIME_DIR=$ROOT/run/xdg-runtime \
HORIZON_NO_AUDIO=1 HORIZON_NO_DISCORD=1 HORIZON_NO_HEARTBEAT=1 \
xvfb-run -a -s "-screen 0 1280x720x24" \
  /path/to/horizon-client \
  --resources /home/solenopsisbot/coding/ari-wt/host/client-chat-line-1969/.local/horizon-client/26.3 \
  --benchmark standard --offscreen
```

`HORIZON_HOME` holds `logs/latest.log`; `--offscreen` keeps the window
invisible. `-a` picks a free X display. Never write to the prepared resource
tree; never write to the repo root.

## 3. Reusable script

`/tmp/opencode/horizon/bench.sh` (outside the repo) does the above and:

- serialises runs with `flock` on `$ROOT/bench.lock` (never benchmark two
  processes on one GPU),
- freezes canonical `options.txt` / `horizon-graphics.txt` under
  `$ROOT/config` and copies them into each run's game folder,
- archives, per run, `reports/raw/<label>-rN-<stamp>.{json,log,meta.json,summary.txt}`,
- records binary path, profile, SHA-256, size, mtime, git commit + dirty count,
  GPU model/driver and used VRAM before/after, load average, exit status.

```sh
/tmp/opencode/horizon/bench.sh \
  --label fast-before --binary target/fast/horizon-client \
  --scenario standard --runs 3
```

Use `--windowed` for a windowed (still vsync-off) run; `--binary` to pick a
build; `--scenario village|forest|ocean|mountain` for a single scene (useful for
debug builds); `--timeout` for a hard cap.

## 4. What it measures and what it does not

Measures:

- End-to-end startup: resource load, shader/pipeline creation, first frame
  (`startup.title_ms`), and world creation/load (`startup.world_ms`).
- Chunk generation + meshing + upload latency around a teleport
  (`chunks.<scene>.load_ms`, counts, chunks/s).
- Steady-state flight rendering over four fixed paths: average FPS, 1% and 0.1%
  low FPS, percentiles, CPU frame time, GPU frame time, histograms.
- Per-render-pass GPU medians for Horizon's own passes (Vulkan/DX12; not Metal).
- Peak and steady RSS, wgpu-allocated GPU bytes, binary size.
- Machine conditions and load average at report creation.

Does not measure:

- The title screen / menus / inventory / any UI beyond the HUD drawn in flight.
- Present-to-display latency, compositor cost or vsync behaviour (vsync is
  forced off; `--offscreen` has no swapchain present at all).
- Multiplayer, dedicated server, or the integrated server in isolation: the
  client and server threads share the process and the measured frame times
  include the server thread's CPU competition.
- Mods (the benchmark disables dev mods; content mods in the game folder still
  load through the normal pack path).
- Disk I/O throughput except as it delays startup/world/chunk loads.
- Total VRAM use: `memory.gpu_mb` is wgpu's allocator accounting only, not the
  driver's, the desktop's, or other processes' VRAM.
- Worst-case spikes rarer than the 4 Hz RSS sampler sees; GPU memory of a
  lost/evicted allocation is not counted.
- Shader-pack compilation beyond what the startup path compiles; per-frame
  pipeline compilation is not forced.

## 5. Pitfalls found on this machine

1. **`--headless` + `--benchmark` deadlocks into the 600 s load limit.** No
   renderer exists, so the title never satisfies `renderer != null`. Use
   `--offscreen`.
2. **Xvfb is required even offscreen.** A window is created
   (`with_visible(false)`); without a display server winit fails. `xvfb-run -a`
   works; the Xvfb screen size does not affect the game's window size
   (`--width/--height`, default 1280x720), but keep it >= the window.
3. **VRAM pressure on a 4 GB card.** This host currently has ~2.0 GB of the
   4096 MiB used by two long-lived llama-server processes (~1025 MiB each),
   leaving ~1.9 GB free before the game starts. The game still starts and runs,
   but any allocation spike can evict/oversubscribe. Record `nvidia-smi`
   before/after; never benchmark while another GPU process is running.
4. **CPU contention dominates the load-sensitive numbers.** The chunk/world
   metrics and 1% lows move by tens of percent with load average; the first
   attempt ran at load ~9-10 (cargo check, clippy, cargo test, a Java server)
   and is archived as `*-contended`, not as a baseline. Check
   `cat /proc/loadavg` and `nvidia-smi` before a run; compare only runs with
   similar load.
5. **World generation is paid on every run.** The benchmark deletes its own
   world and regenerates seed 1234, so there is no cross-run world cache. That
   makes `startup.world_ms` and `chunks.*.load_ms` comparable across runs but
   *not* comparable to a player's warm save.
6. **Pipeline/shader compile is per process.** There is no disk pipeline cache
   in this tree; the first frames of every run pay the same compile cost, and
   `startup.title_ms` includes it. OS page cache for the resource tree/binary
   is the only true warm-up benefit, so run once unrecorded after boot to warm
   the page cache, or report run 1 separately.
7. **`options.txt` and `horizon-graphics.txt` are inputs.** The benchmark does
   not pin render distance, simulation distance, resolution, graphics preset,
   particles, LOD, culling or shader pack. Changing them invalidates a
   comparison; the script freezes both files.
8. **Frame cap:** the report's `vsync`/`fps_cap` fields are the forced values
   (`false` / unlimited). The benchmark sets `settings.maxFps = 260`, which is
   this engine's sentinel for *unlimited* (`settings.rs`: `>= 260` means no
   limit), not a 260 FPS cap. Offscreen frames are not paced by a swapchain, so
   the measured rate is submission/GPU throughput, not a presented frame rate.
9. **`repeats = 1`.** One report is one sample. The format supports multiple
   repeats but this driver writes one; do 3 process runs and aggregate
   externally.
10. **Debug builds are not a baseline.** They validate the protocol only:
    resource load ~5.6 s vs ~0.9 s fast, worldgen ~2.8 s vs ~0.29 s, and
    shader compilation is far slower. Use `--scenario ocean` for a smoke test.
11. **GPU memory already in use by other processes can silently change the
    adapter.** If the NVIDIA device cannot be opened, `device_search` falls
    back to other backends and finally a software adapter (llvmpipe/lavapipe);
    the report's `hardware.gpu.backend` and name will say so. Always check the
    report's GPU block, not just "it ran".
12. **This host has a co-tenant GPU workload.** Two llama-server processes hold
    ~1.0 GB VRAM each, and during this session another session's
    `horizon_client_render` test binary held ~1.07 GB and intermittently drove
    the GPU to 98% SM. That is what produced the 2.8x run-to-run swing in
    `gpu_p50` (1.14 vs 3.18 ms) while `cpu_p50` stayed flat. `nvidia-smi pmon`
    before and during every run; `bench.sh` samples util/clock/power/temp/VRAM
    every second into `<tag>.gpu.csv` and records peak VRAM, median SM clock,
    median/max util in the `.meta.json`.
13. **The GTX 970 sits at 135 MHz (P8, ~19 W) when idle and reaches ~1400 MHz
    (P0) under load.** A 12 s flight after several seconds of CPU-only chunk
    generation can be spent ramping. `nvidia-settings -a
    '[gpu:0]/GPUPowerMizerMode=1'` on the Xorg display `:1` reported success
    and raised clocks to 1177 MHz, but the setting did not persist (the driver
    returned to P8/P5 within seconds), and `nvidia-smi -lgc` needs root. Record
    the clock samples; do not assume two runs saw the same clock.
14. **There is a real Xorg on `:1`** (plus Xvfb for our runs). Do not assume
    "no display"; GPU-using processes launched by other sessions can appear and
    disappear between checks. The benchmark itself only needs an X display for
    winit's invisible window and uses Vulkan headless otherwise.

## 6. How to compare two builds

Same machine, same binary profile, same `options.txt`/`horizon-graphics.txt`,
same scenario, same `--offscreen` mode, same display state and similar load
average. Never compare a `fast` build with the `lite`/PGO or debug build.

1. Warm the page cache with one unrecorded full run (or discard run 1).
2. Run **3 measured runs per build**, alternating order (`A B A B A B`) to
   spread thermal/background drift rather than measuring all of A then all of
   B.
3. Keep each build's `benchmarks/` report and the script's `.meta.json`.
4. Aggregate per scene: mean and sample stdev across the 3 runs for
   `avg_fps`, `low_1pct_fps`, `startup.title_ms`, `startup.world_ms`, each
   `chunks.*.load_ms`, `memory.rss_peak_mb`, `memory.gpu_mb`. The comparison
   table below is the intended shape.
5. Report the changed metric and its CI, not just the best run. A single 3-run
   mean difference smaller than ~2x the stdev is not evidence.
6. If the change is meant to affect a specific subsystem, also quote the
   matching `gpu_pass.*` metric (GPU) and `cpu_p50_ms` (CPU) so a win in one
   place is not a regression hidden in the other.
7. Archive the failing/contended runs separately, never in the means.

### Comparison template

Build A: `<profile> <sha256:12> <commit> <dirty?>`, date:
Build B: `<profile> <sha256:12> <commit> <dirty?>`, date:
Conditions: GTX 970 4 GB, driver ..., 1280x720 offscreen, vsync off, RD 12 /
sim 12, seed 1234, load avg A/B ..., GPU VRAM free A/B ...

| Metric (mean of 3) | A | B | B/A | Stdev A | Stdev B | Verdict |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| startup.title_ms | | | | | | |
| startup.world_ms | | | | | | |
| fps.village.avg_fps | | | | | | |
| fps.village.low_1pct_fps | | | | | | |
| fps.forest.avg_fps | | | | | | |
| fps.forest.low_1pct_fps | | | | | | |
| fps.ocean.avg_fps | | | | | | |
| fps.ocean.low_1pct_fps | | | | | | |
| fps.mountain.avg_fps | | | | | | |
| fps.mountain.low_1pct_fps | | | | | | |
| chunks.village.load_ms | | | | | | |
| chunks.forest.load_ms | | | | | | |
| chunks.ocean.load_ms | | | | | | |
| chunks.mountain.load_ms | | | | | | |
| memory.rss_peak_mb | | | | | | |
| memory.gpu_mb | | | | | | |
| game.binary_bytes | | | | | | |

Per-scene detail (from each report): p50/p95/p99/p999/max frame ms,
`cpu_p50_ms`, `gpu_p50_ms`, histogram, `gpu_pass.<scene>.*_ms`,
`chunks.*.generated_per_s`.

## 7. Baseline (fast profile, canonical settings)

Binary: `target/fast/horizon-client`, fast profile (release, no LTO, 16 CGUs),
108,049,880 bytes, SHA-256 `75d111a7d6a2c1b5…` (rebuilt 17:06 with the
mod-dispatch change; the earlier baseline binary is archived as
`/tmp/opencode/horizon/horizon-client-baseline`, SHA-256 `824c248b801280e1…`,
107,991,976 bytes, built 16:53).

Conditions: GTX 970 4 GB, driver 580.196.07, Vulkan, 1280x720 offscreen,
vsync forced off, fps unlimited, render distance 12, simulation distance 12,
seed 1234, creative, `options.txt` / `horizon-graphics.txt` frozen from the
first launch of this tree. 3 process runs, one benchmark each, archived under
`/tmp/opencode/horizon/reports/raw/fast-baseline-r*.json`.

| Metric | Mean | Stdev | Min | Max |
| --- | ---: | ---: | ---: | ---: |
| startup.title_ms | 1540.0 | 119.8 | 1423.4 | 1662.7 |
| startup.world_ms | 4619.1 | 819.2 | 3829.6 | 5465.1 |
| fps.village.avg_fps | 728.2 | 249.8 | 532.0 | 1047.9 |
| fps.village.low_1pct_fps | 96.8 | 54.3 | 57.9 | 166.7 |
| fps.forest.avg_fps | 423.7 | 280.1 | 235.6 | 785.2 |
| fps.forest.low_1pct_fps | 63.3 | 70.7 | 15.9 | 154.5 |
| fps.ocean.avg_fps | 532.1 | 345.5 | 285.8 | 977.3 |
| fps.ocean.low_1pct_fps | 112.2 | 134.6 | 20.2 | 285.9 |
| fps.mountain.avg_fps | 538.1 | 357.1 | 295.6 | 998.9 |
| fps.mountain.low_1pct_fps | 108.6 | 132.8 | 21.7 | 280.0 |
| chunks.village.load_ms | 2636 | 831 | 2156 | 3596 |
| chunks.forest.load_ms | 3264 | 338 | 2878 | 3505 |
| chunks.ocean.load_ms | 2725 | 577 | 2254 | 3369 |
| chunks.mountain.load_ms | 5156 | 1145 | 4305 | 6457 |
| memory.rss_peak_mb | 1418.7 | 27.7 | 1397.4 | 1450.0 |
| memory.rss_steady_mb | 1212.8 | 25.5 | 1190.3 | 1240.5 |
| memory.gpu_mb | 414.3 | 4.6 | 409.0 | 417.0 |
| game.binary_bytes | 107,991,976 | - | - | - |

**These are not publishable as a clean baseline.** GPU frame time varied by
~2.8x between identical runs (`gpu_p50` 1.14 vs 3.18 ms in forest) while CPU
frame time stayed at 0.37-0.77 ms: a co-tenant process was using the GPU during
part of the session. See pitfall 12 and the A/B note in the companion
`perf-ab.md`; the A/B uses alternating runs and paired ratios so the drift
hits both builds.

Load-sensitive numbers (`startup.world_ms`, `chunks.*.load_ms`) were also taken
at load average 4.7-9.1 (CI compiles and a Java server on 16 threads); treat
them as an upper bound. Offscreen FPS is submission/GPU throughput without
present, not a presented frame rate; do not compare these numbers to a player's
on-screen FPS.
