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

## Caveats

- These describe **upstream**, not this fork. Some numbers have already changed here: the launcher,
  Realms, `horizon-server`, the tooling and the Python test infra are gone, and the default build
  no longer includes controllers or `horizon-extras`.
- Line counts are `wc -l` ±1 per file; "LOC" is used consistently as a size proxy, not a measure of
  difficulty.
- Effort estimates are the agents' judgements, not measured.
