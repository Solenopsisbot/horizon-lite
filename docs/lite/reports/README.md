# Subsystem audits

These nine reports were produced by parallel agents on 2026-11-08, read-only, against upstream
Horizon at commit `4e6920a`. They are the evidence behind [`../PLAN.md`](../PLAN.md).

| Report | Scope | Why read it |
|---|---|---|
| [`game.md`](game.md) | `game.rs` + `game/` — 324k LOC in 467 files | The single-player-is-a-server finding, the 77-file walking skeleton, per-file CUT/GATE/CORE verdicts, ranked removals |
| [`render.md`](render.md) | Renderer, graphics, packs — 223k | What is vanilla vs Horizon extra; the HDR-in-the-mesher trap; `gfx.rs` cut regions |
| [`world.md`](world.md) | `horizon-world` — 193k | LOC per worldgen stage, datafixer anatomy, redstone as a call-site problem |
| [`net.md`](net.md) | Protocol, LAN, servers | Exact split between external network surfaces and the in-process loop single player needs |
| [`assets.md`](assets.md) | Assets, packs, mods, shaders | The mod-API build-script tar pit; what the resource preparer actually needs |
| [`ui.md`](ui.md) | UI, input, audio, cosmetics | `Screen` enum coupling, minimum playable UI, the controller code that compiles even when off |
| [`features.md`](features.md) | Cargo features, cut mechanics | Every feature site, optional-dep deltas, the C1–C14 deletion order with verify commands |
| [`infra.md`](infra.md) | Launcher, tools, tests, CI, docs | Why the launcher is unnecessary, build inputs hidden in `tools/` and `mods/`, CI replacement |
| [`product.md`](product.md) | Product tiers, invariants, branding | Tier A/B/C comparison, licensing and maintenance strategy, risk register |

### Performance round (2026-11-08, GTX 970 / Ryzen 3700X)

| Report | Scope | Headline |
|---|---|---|
| [`perf-frame.md`](perf-frame.md) | Per-frame hot path | Optional features are idle-gated; the real costs are the HUD rebuild, per-text allocations and always-on instrumentation |
| [`perf-render.md`](perf-render.md) | Renderer, defaults, GPU | Defaults were the problem (RD 12, clouds at 128 chunks, VSync/120 cap); deletion buys ~0 FPS because features are off by default |
| [`perf-tick.md`](perf-tick.md) | Tick/TPS, chunk pipeline | Mob AI dominates; raids/patrol/sculk scan every mob while idle; simulation distance is the cleanest TPS scaler |
| [`perf-memory.md`](perf-memory.md) | RSS and VRAM | Chunk encoder wire cache (60–190 MB), startup tables (120–220 MB), GUI atlas (84 MB VRAM) |
| [`perf-build.md`](perf-build.md) | Build flags, allocator, startup | PGO 5–15%, native 2–8%, fat LTO 1–4%, mimalloc purge 1–5%, pipeline-cache startup win |
| [`perf-optional.md`](perf-optional.md) | Cross-cutting feature costs | The cost model is upside down: all the features you would delete are runtime-inert; the mod API is the exception |
| [`perf-modapi.md`](perf-modapi.md) | Native mod dispatch | 507 hooks, 655 call sites; zero-mod cost 0.1–0.5% CPU; one generator guard removes it |
| [`perf-measure.md`](perf-measure.md) | Benchmark protocol | How to run `--benchmark`, pitfalls (Xvfb, offscreen, VRAM, contention), comparison template |

## Caveats

- These describe **upstream**, not this fork. Some numbers have already changed here: the launcher,
  Realms, `horizon-server`, the tooling and the Python test infra are gone, and the default build
  no longer includes controllers or `horizon-extras`.
- Line counts are `wc -l` ±1 per file; "LOC" is used consistently as a size proxy, not a measure of
  difficulty.
- Effort estimates are the agents' judgements, not measured.
