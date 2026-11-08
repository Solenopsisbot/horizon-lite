# Horizon Lite renderer — performance audit for a GTX 970 at 1280×720

**Tree:** `horizon-lite` @ `94ef964` (read-only; no builds, no GPU runs)
**Target:** GeForce GTX 970 4 GB, Vulkan, Linux, 1280×720 (921,600 pixels)
**Scope:** `crates/horizon-client-render/` (`gfx.rs`, `gfx/`, `graphics*.rs`, `settings.rs`, `weather.rs`, `clouds.rs`, `fog.rs`, `shadow*`, `hdr*`, `lod*`, `bluemap*`, `server_terrain.rs`, `particles.rs`, `block_entity_render.rs`, `post_chain.rs`, `overlay.rs`, `first_person*`), the client's frame build (`game.rs`, `render_tick.rs`), and the graphics crates/shader API.

All FPS numbers below are **estimates** from the code's workloads (pixels, vertices, passes, uploads), not measurements. They are given as ranges because the frame is scene-dependent and, at 720p on a 970, frequently CPU-bound. The existing `docs/lite/reports/render.md` is the LOC/feature audit; this report is the frame-time audit.

---

## 0. Executive summary

1. **The renderer is already unusually lean in steady state.** With default settings (no pack, no HDR, no OIT, no TAA, 100% resolution, no LOD) a world frame is typically **2–3 render passes**: the world pass, an optional occlusion-culling phase-2 pass, and the HUD. There is no MSAA, no shadow map, no G-buffer, no extra world target, and no per-frame pipeline creation.
2. **The default settings, not the renderer, are the biggest FPS problem.** `Settings::default()` ships render distance 12, simulation distance 12, fancy 3D clouds at **128 chunks**, VSync on, a 120 fps cap, all particles, entity shadows, fancy cutout leaves, and a `"fancy"` label whose values do not match what Fancy actually sets.
3. **The single largest default cost is cloud distance.** `cloud_range: 128` means a cell radius of 171 cells and roughly **91,000 cells** (`clouds.rs:61–63`); the fancy mesh emits a top face plus exposed sides for every filled cell. Dropping the range to 32 cuts the cell count ~16×. Turning clouds off also removes the CPU rebuild hitch that occurs whenever the camera or cloud drift crosses a 12-block cell.
4. **The biggest LOC deletions buy ~0 FPS.** LOD/BlueMap/server terrain (13.7k LOC), shader packs (~45k), HDR (2.2k), OIT (1.6k), GPU culling (3.5k), visbuffer, frame generation and FXAA/TAA/upscaling are all **off by default**. Deleting them changes startup, binary size and risk, not steady-state frame time. Turn them off — they already are — and spend the effort on defaults.
5. **At 720p/970 the frame is likely CPU-bound in normal play.** The 4080 benchmark in `docs/graphics.md:172–179` shows 1–3 ms CPU vs 0.2–0.9 ms GPU at render distance 16. A 970 renders 720p cheaply; a 970-era CPU does the section walk, entity/block-entity/particle geometry and draw-list build. Prioritise CPU work: render/simulation distance, entity distance, particles, block entities, culling defaults.
6. **Do not delete `flat`/shader-pack capability blindly.** On NVIDIA Vulkan the flat-draw path itself is not used without a pack, but its presence enables **packed terrain quads** (`gfx.rs:4700–4701`): one 24-byte record per solid quad instead of four 24-byte vertices, a ~4× cut in terrain arena traffic (`mesher/packed.rs:1–9`). Deleting it without preserving `packed_quads` is a large bandwidth regression.
7. **Keep the features that save time:** section side culling (`gfx.rs:4855`), cave culling, GPU occlusion culling (self-gating), translucent batching, entity batching, GPU skinning, packed quads, the auto upload throttle, and the Linux submit thread (measured +32% FPS in its own comment, `gfx/submit.rs:14–24`).

---

## 1. What is submitted per frame

### 1.1 Frame path and render passes

`Game::render_frame` (`crates/horizon-client/src/game.rs:13756`) builds the frame, then `Renderer::render` (`gfx.rs:7689`) calls `draw_frame` (`gfx.rs:7807`). `draw_frame` owns the command encoder and submits it, usually on the `Render submit` thread.

Typical **world** frame at defaults, day, ground level, no pack/HDR/OIT/TAA:

| # | Pass | When | What it does |
|---|---|---|---|
| 1 | `"Horizon world"` (`gfx.rs:10185`) | always | clears colour+depth; sky disc/sunrise/celestial/stars; all solid terrain; entities, static block entities, particles, block entities; translucent terrain; clouds; weather; world border; first-person hand (drawn in this pass by default, `gfx.rs:9754–9760`, `11183–11188`) |
| 2 | `"World after culling"` (`gfx.rs:289–324`, `10404/10999`) | when GPU occlusion culling's gate is on | loads colour+depth, draws the phase-2 solid sections the box test found visible, then translucent terrain and the rest of the world. `StoreOp::Store` on depth while culling is active (`gfx.rs:10195–10199`) |
| 3 | HUD (`hud.draw_range`, `gfx.rs:11964`, `12016`) | always | hotbar/chat/boss bar/crosshair etc.; one to three passes depending on menu blur splitting the batch |
| 4 | `"Screen effects"` (`gfx.rs:11851`) | only when `frame.screen` has quads | underwater/fire/block overlay/pumpkin/portal/dark vignette; the daylight vignette is skipped when its colour is black (`screen_effects.rs:260–265`), so this is usually absent |
| 5 | `"First-person hand"` (`gfx.rs:11696`) | only when the hand cannot be folded into the world pass | off under a pack, scaled world, HDR, frame generation, or a native world-drawn hook |
| 6 | Entity outline (5 passes: silhouette + Sobel + two blurs + blit) | only when glowing entities exist | `gfx/entity_outline.rs:266–318` |
| 7 | `post_effect` chain | only when spectator/creeper/spider/invert effects are active | `post_chain.rs` |
| 8 | `"Menu blur"` (6 full-screen passes) | menus with blur ≥1 | `menu_blur.rs:15–22` |
| 9 | `world_post` (1 pass) | only when resolution scale ≠100%, FXAA or TAA is on | `gfx/world_post.rs:334–340` returns `None` at native/no-AA, so no pass |
| 10 | HDR / pack shadow / pack post / frame-gen | only when enabled | all off by default |

**Default gameplay total: 2–3 passes; 3–4 when culling runs; 1 more in water/fire/darkness; menus add six blur passes.**

### 1.2 Draw calls

On Vulkan/NVIDIA with the default settings:

- **Terrain is not one draw per section.** `multi_draw` is enabled (`gfx.rs:4711–4714`), and `draw_sections_from` issues one `multi_draw_indexed_indirect` per contiguous run of draws in the same arena page (`gfx.rs:5986–6021`). Arena pages hold `1 << 20` vertices (`gfx.rs:4620–4625`). At render distance 12 expect roughly **4–12 terrain draw calls** (solid phase 1, phase 2, translucent), while the CPU still prepares **~1,000–3,000 draw entries** (one per section side-run).
- The flat/visibility-buffer path is **not** used on NVIDIA Vulkan without a pack: `flat::for_vanilla` is false, so `min_sections = usize::MAX` (`gfx.rs:4637–4647`). It exists for shader packs, Metal and broken Intel Vulkan. No flatten compute pass runs by default.
- **Entities/materials:** about 10–20 draws (ordinary entities, text, shadows, translucent items, crumbling, water mask, lightning, swirl, additive, fluid, three native terrain-model materials, world text ×2, see-through). Each material is a separate pipeline/draw even though all vertices live in one buffer.
- **Static block entities:** one indexed draw per visible cached section (`gfx.rs:10595–10614`); with the default caches only signs are cached, so usually 0–5, more in a village/sign-heavy base.
- **Sky/celestial:** 1–4 draws (sky triangle, sunrise fan at dawn/dusk, sun/moon, stars, End sky).
- **Clouds 1, weather 1, border up to 6, hand 1, HUD 1–10.**
- **Typical total: ~30–70 draw calls.** That is low; the CPU cost is in building the lists and geometry, not in the API call count. On OpenGL the same frame loops over each section (`multi_draw` absent or CPU-unrolled), which is one reason to stay on Vulkan.

### 1.3 Bind groups

Distinct layouts: terrain group 0 (globals, sprite array, lightmap, emission stats), the per-page group 1 for pulled solid draws, entity group 0/1, cloud group, border group, hand group, HUD group, cull group. About **8 layouts and 15–40 `set_bind_group` calls per frame**.

Reuse is already good:
- Terrain groups are created once in `Renderer::new` (`gfx.rs:3459–3519`).
- Per-page groups and their arena bindings are cached (`gfx/flat.rs` `PageTable`).
- The cull group is rebuilt only when the origin/globals buffer identity changes (`gfx/cull.rs:561–567`).
- Entity/cloud/hand groups are permanent.

No per-frame bind-group creation is a meaningful cost here.

### 1.4 Uploads per frame

`Uploads` is a `StagingBelt` (1 MiB chunks for the frame; 4 MiB for section meshes, `upload.rs:8–27`, `gfx.rs:868`). All copies are recorded into the frame encoder, so there is no per-write staging allocation.

| Upload | Size / cadence |
|---|---|
| `Globals` ×3 (world, hand, crosshair) | 3,744 B each = ~11 KiB/frame (`gfx.rs:398–435`) |
| Section instance origins | 16 B × (visible + LOD + shadow sections) ≈ 16–64 KiB/frame |
| Indirect draw list | 20 B × section draw entries ≈ 20–60 KiB/frame |
| Entity vertex buffer | `Vertex` is 44 B; 20k–100k vertices typical = 0.9–4.4 MiB/frame |
| Section meshes | `TerrainVertex` is 24 B, but solid quads are packed to **one 24 B record per quad** (≈4× smaller than four vertices) when packed quads are on, which they are by default on NVIDIA; `Game::update_world` throttles uploads to **2 ms CPU/frame** (6 ms while terrain is arriving) via `AUTO_UPLOAD_TIME` (`game.rs:591–597`, `14895–14907`); up to 64 MiB may be staged before an early submit (`SECTION_COPY_LIMIT`, `gfx.rs:871`) |
| Cloud mesh | 44 B/vertex; a full 128-chunk fancy mesh is on the order of 0.7–8 MiB, uploaded only when the camera or drift crosses a 12-block cell (`clouds.rs:324–375`), i.e. every ~20 s while stationary, more often while flying |
| Weather | 4 vertices × 441 columns × 80 B ≈ 141 KiB/frame while raining (`weather.rs` `Vertex`; radius 10 → 21×21 columns) |
| HUD/screen/outline/border | tens of KiB/frame |
| Lightmap | 16×16 RGBA8 = 1 KiB, only when the computed table changes (`gfx.rs:7603–7621`) |
| Animated atlas sprites | small mip uploads only for active animated layers and only when their frame changes (`gfx.rs:7623`) |
| Arena compaction | `COMPACT_BUDGET = 32 MiB` per frame when a page is closing (`gfx.rs:876`, `6063–6104`); can be a visible hitch |

### 1.5 CPU/GPU sync points

There is **no per-frame `device.poll(wait)`** in the normal world path. The real waits are:

1. **Previous frame handoff.** `draw_frame` starts with `self.land_frame()` (`gfx.rs:12138–12155`), which calls `Queue::landed()` → `Queue::wait()` and blocks on the submit thread's `done_rx.recv()` until the previous frame was submitted and presented (`gfx/submit.rs:128–161`). This is counted as `last_wait`, not CPU work. With VSync/FIFO it is the display; with VSync off it is the GPU/submit thread.
2. **Swapchain acquire** (`surface.get_current_texture()`, `gfx.rs:7908`) — can block when the CPU is ahead of the display.
3. **Present** (`queue.present`, `gfx.rs:11626`); with FIFO, `pre_present_notify` ties the frame to the compositor (`gfx.rs:11620–11622`).
4. **Occlusion-culling readback.** `Cull::begin` does a non-blocking `device.poll(PollType::Poll)` (`cull.rs:396–397`) and consumes results mapped 1–3 frames earlier (`READBACKS = 3`, `cull.rs:76–80`). It never waits for the current frame.
5. **Screenshots/world icon:** `read_frame` uses `poll(wait_indefinitely)` (`gfx.rs:12209–12218`) — a full GPU sync, only for F2/capture.
6. **Offscreen:** at most two frames in flight, `wait_frames` polls submissions (`gfx.rs:12169–12177`); not used with a window.
7. **Surface reconfigure/compositor:** `wait_submissions` (`gfx.rs:12166–12168`), rare.

Staging-buffer reuse is tied to submission completion by `StagingBelt::finish_and_recall_on_submit` (`upload.rs:118–120`); it does not stall the CPU.

### 1.6 CPU frame build (before the GPU)

The expensive CPU work is in `Game::render_frame` and `draw_frame`:

- `entity_geometry` (`game.rs:9572`) iterates every mob, dropped item, armor stand, projectile, block entity and particle, applies per-entity view distance and frustum culling, and appends vertices. In a base, the block-entity path scans visible block entities twice: once for the camera list and once for cache candidates (`game.rs:9882–10016`).
- `start_occlusion` (`game.rs:13947`) runs the cave graph search on a worker; `sections.walk` (`gfx.rs:8373–8391`) walks the reached sections.
- Draw-list building, side-run splitting (`facing_runs_from`), translucent sort (`count/8`, at least 15 sections/frame, `gfx.rs:8789–8897`), instance packing, indirect upload.
- `compact_arena`/`shrink_translucent` can move up to 32 MiB/frame when pages close (`gfx.rs:6063–6210`).
- Command encoding then happens on the submit thread on Linux (`submit.rs`), which is why the comment records +32% FPS on Vulkan.

At 720p on a 970-era CPU this is the limiter. The 4080 table at RD 16 shows 1.0–3.2 ms CPU vs 0.2–0.9 ms GPU; at 720p the GPU side shrinks further.

### 1.7 Shader inventory

The tree has **48 `.wgsl` files, 6,408 lines**. The default world path compiles and uses: `terrain.wgsl` (section/instance, solid/cutout/translucent), `entity.wgsl` + `static_entity.wgsl`, `screen.wgsl` (HUD/screen effects), `border.wgsl`, `entity_outline.wgsl`, `cull.wgsl` and `gfx/wgsl_prefix.rs`'s generated prefix. The sky/stars/end-sky/cloud/weather/hud/menu-blur/cull modules are created in `Renderer::new`; HDR (`hdr.wgsl`, `hdr_stats.wgsl`), OIT (`oit*.wgsl`), visbuffer (`visbuffer.wgsl`), frame generation (`gfx/frame_gen/*.wgsl`) and pack shaders are compiled only when their feature is switched on (or, for the pack path, when a pack is loaded). A shader pack is therefore a compile-time + runtime cost only when picked; the dormant `.wgsl` files cost disk space, not frame time.

---

## 2. Optional renderer features and their cost on a 970 / 720p

“Delete gain” is the steady-state FPS gain from removing the feature entirely when it is **active**. If it is off by default, deleting it is a code-size/risk decision, not an FPS win.

| Feature | Default | Cost when active | Delete gain | Risk / note |
|---|---|---|---|---|
| **Distant terrain LOD** | **off** (`lod_distance: 0`, `graphics.rs:785`) | 64–1024 chunks adds far tiles; 1–10 ms GPU depending on range/detail; millions of quads at high range | **~0** at default | Deleting 13.7k LOC buys nothing unless the player enabled LOD. If enabled, setting 0 is one of the biggest wins. |
| **BlueMap far terrain** | **off** (needs `blueMap:` or auto-detect; `bluemap.rs`) | HTTP tiles + far tile meshes only on servers | **~0** | Same: dormant without a configured server map. |
| **Server-kept far terrain (Bobby)** | **off** (only with LOD > 0; `game.rs:14559–14568`) | reads region files, builds far tiles | **~0** | `ServerTerrain` is not constructed while LOD is 0. |
| **Shader packs (`shaders/` and `.hshader`)** | **none picked** (`shader_pack: ""`) | shadow pass + 10–40 post passes + material/terrain variants; typically 2–4× frame time at 720p | **~0** at default | Deleting ~45k LOC + 22k pack code is the largest deletion, but zero default FPS. High risk: locale/format code shared with other features. |
| **HDR output** | **off** (`hdr: false`) | 16-bit frame (`Rgba16Unorm`), extra present/mark passes; +20–60% frame bandwidth at 720p, plus 1–3 full-screen passes | **~0** | `hdr_lighting: true` is inert without HDR. Deleting HDR is 0 FPS but touches `frame_format`. |
| **Shadows** | no shadow map; **entity blob shadows on** (`entity_shadows: true`); pack shadows off | blob shadows: one quad per entity, one extra draw; <1% | **<1%** | There is no vanilla shadow-map feature to delete. Pack shadow support is dormant. |
| **Translucency / OIT** | vanilla blend; **OIT off** (`improved_transparency: false`) | vanilla translucent sort ~0.1–0.3 ms CPU; OIT would add fragment targets/composite passes | **~0** (OIT) | Deleting OIT is 0 FPS. Deleting the sort breaks water/glass order; not worth it. |
| **Particles** | **all** (`particles: 0`; 1 = decreased, 2 = minimal) | simulation + geometry; 1–5% typical, 15–30% in farms/explosions | **1–5%** typical, **15–30%** heavy | Low-medium: gameplay feedback. The cheapest fix is default 1–2, not deletion. |
| **Clouds** | **fancy 3D, 128 chunks** (`clouds: "true"`, `cloud_range: 128`) | ~91k cells, top face + sides per filled cell; 3–12% when sky visible; CPU rebuild spike every 12 blocks of camera/drift | **3–12%** when visible | Low risk (visual). Top feature-level win. |
| **Weather** | **on**, radius 10 (`weather: true`, `weather_radius: 10`) | 441 columns, alpha-blended full-screen overdraw; 3–8% while raining; CPU `rain_height`/precipitation per column | **3–8%** in rain, 0 clear | Low-medium. UI itself labels Weather “High cost” (`graphics_ui.rs:279`). |
| **Block entities** | **on**; only sign cache on (`cache_signs: true`, others false) | per-block model geometry and light sampling every frame; 1–10% in a base, 0 elsewhere | **1–10%** in bases | High risk: deleting renderers makes chests/signs/bells invisible. Better: turn the caches on. |
| **First-person hand** | on when an item is held | one draw in the world pass + a depth-reset triangle; ~0.05–0.15 ms | **~0.1%** | High visual cost for negligible gain. |
| **Screen effects** | vignette on, but skipped in daylight; underwater/fire/portal as needed | 1 pass + 1 quad when active; 0.1–0.5 ms underwater/fire | **~0–1%** | Not worth deleting. |
| **Panorama / menu blur** | panorama on title; blur 5 (`menu_blur: 5`) | title cube is one draw; blur = 6 full-screen passes over 720p, ~0.5–1.5 ms | **0 gameplay** | Menu FPS only. Reducing blur passes or radius is the keep-feature win. |
| **Entity batching** | **on** | CPU copy into per-material runs; enables ~10 draws instead of hundreds | **negative to delete** | Keep. |
| **GPU skinning** | **on** (`entity_skin` constructed unconditionally, `gfx.rs:4599`) | one compute dispatch + storage buffer; ~0.05–0.2 ms for a few hundred mobs | **negative to delete** | Keep; deleting moves vertex posing back to the CPU. |
| **Occlusion culling (section boxes)** | **on for discrete GPUs** (`gfx.rs:94–96`, `4772–4785`) | phase-2 pass + box draw; self-gates off when <10% of solid indices are hidden, probing 1/64 frames (`cull.rs:53–64`) | **negative at RD≥16**; wash at RD 12 | Keep. `HORIZON_GPU_CULL=0` is the A/B switch. |
| **GPU culling** | **off** (`gpu_culling: false`) | compute pass + count draws; moves CPU work to GPU | **~0** default | For fast GPUs/high RD; on a 970 at 720p it can be slower. |
| **Frame generation (FSR 3.1)** | **off** | optical flow + interpolation + extra present; ~1–2 ms and +1 frame latency; raises *presented* FPS | **~0** default | Not a render-time win; deleting it is 0. |
| **FXAA / TAA / upscaling** | **off / native** | FXAA 1 full-screen pass; TAA 2 passes + history; upscaling renders 1.5–3× fewer pixels per axis | **~0** default | Off by default. Upscaling is a *speed lever* (keep the feature), not a deletion target. |
| **MSAA** | **not implemented** | — | — | `docs/graphics.md:114`; nothing to disable. |
| **Visbuffer** | **off** (`HORIZON_VISBUFFER`) | extra ID pass + full-screen resolve | **~0** default | Experimental; leave off. |
| **Resolution scale** | **100%** | below 100% renders fewer pixels, then copies up | — | A speed lever, not a feature cost. |

---

## 3. Graphics/settings defaults and a “speed” default set

### 3.1 What `Settings::default()` actually ships

`crates/horizon-client-render/src/settings.rs:218–303`:

| Setting | Default | Verdict for speed |
|---|---:|---|
| `render_distance` | **12** | **Bad.** Biggest single cost. 625 columns vs 289 at 8 (−54%). |
| `simulation_distance` | **12** | **Bad for CPU/p99.** In-process server tick, mob AI, block entities share cores with the renderer. |
| `graphics_preset` | **"fancy"** | **Misleading.** It is only a stored label until the UI applies it; the numeric values do not match `options_ui::apply_preset("fancy")` (which sets RD 16, cloud range 64). |
| `entity_distance` | **1.0** | Moderate; at RD 12 the entity view scale is `(12/8).clamp(1,2.5) = 1.5` (`entity_culling.rs:374–376`), so entities draw out to ~1.5× their base range. 0.5 halves that. |
| `mipmap_levels` | **4** | **Good; keep.** Mips improve texture cache behaviour. Lowering to 0 increases shimmer and can cost bandwidth/cache misses; the UI labels it “No cost” (`graphics_ui.rs:322–325`). Not a speed win. |
| `vsync` | **true** | **Bad for max FPS.** Caps to the display (usually 60). Input latency higher. |
| `max_fps` | **120** | **Bad with VSync off.** Caps at 120; a 970 at 720p can exceed it. |
| `clouds` | **"true"** (fancy 3D) | **Bad**, especially with range 128. |
| `cloud_range` | **128 chunks** | **Worst default.** 171-cell radius, ~91k cells; also forces `depth_far` to 2048 (`camera.rs:857–858`). |
| `particles` | **0 = all** | Bad in heavy scenes; 2 = minimal. |
| `entity_shadows` | **true** | Minor bad; blob shadow quads for every entity. |
| `biome_blend` | **2** | Mesh-time CPU only; not a frame-time win once settled. |
| `smooth_lighting` | **true** | Mesh-time CPU only; not a frame-time win. |
| `weather_radius` | **10** (21×21 = 441 columns) | Bad in rain; 3–5 is 4–11× fewer columns. |
| `cutout_leaves` | **true** (fancy) | Bad in forests: alpha-tested, no early-Z. |
| `improved_transparency` | **false** | Good (OIT off). |
| `menu_blur` | **5** | Menus only; six full-screen passes. |
| `vignette` | **true** | Tiny; skipped in daylight. |
| `max_fps`/VSync notes | — | The comment at `settings.rs:231–232` explains 120 is vanilla's default; it is still a cap. |

### 3.2 `Graphics::default()` (`graphics.rs:781–836`)

| Setting | Default | Verdict |
|---|---|---|
| `lod_distance` | **0** | **Good.** LOD off; do not “fix” it. |
| `cave_culling` | **true** | **Keep.** Big win. |
| `gpu_culling` | **false** | Good for 720p/970. |
| `entity_culling` | **Off** | **Missed win.** Async mode hides mobs behind terrain. |
| `particle_culling` | **Off** | **Missed win.** Async skips off-screen/occluded particles. |
| `leaf_culling` | **Off** | **Missed win.** `Hollow` drops hidden leaf faces (visual holes). |
| `cache_signs` | **true** | Good. |
| other block caches | **false** | **Missed CPU win** in bases. |
| `chunk_updates` / `upload_budget_kib` | **0 / 0** | Not “unlimited”: auto limit is 2 ms CPU/frame (6 ms arriving), `game.rs:591–597`. Good default; explicit budgets can disable the time-based limiter. |
| `sky` / `fog` / `weather` | **true / true / true** | Sky/fog keep the look cheaply; weather is the expensive one. |
| `animated_textures` | **true** | Small per-tick upload cost; <1%. |
| `resolution_scale` | **100** | Good for quality; 75–85 is a big GPU lever. |
| `fxaa` / `taa` / `upscaling` | **false / false / Native** | Off; good for speed. |
| `frame_generation` | **Off** | Good. |
| `hdr` | **false** | Good. |
| `translucent_batching` | **true** | **Keep.** Saves draw calls, most over water/high RD. |
| `present_mode` | **Auto** (`Fifo` with VSync, else `Immediate`/`Mailbox`/`Fifo`) | Good with VSync off. |
| `pacing` | **Efficient** | Good. |
| `workers` | **0** (all cores but one) | Reasonable; more workers help streaming, not settled FPS. |
| `api` | **Auto** (Linux: Vulkan, then GL) | **Keep Auto/Vulkan.** GL loses multi-draw batching and translucent batching (`translucent_batchable` returns false on GL, `gfx.rs:117–119`). |

**Important implementation detail:** changing `Settings::default()` only affects a *missing* `options.txt`. An existing `options.txt` missing a key falls back to `options_file.rs` defaults (`maxFps` 120 at line 156, `cloudRange` 128 at 164, `renderDistance` 12 at 165, `simulationDistance` 12 at 166, `weatherRadius` 10 at 170, `particles` all at 161). To make a speed default effective for existing installs you must change both, or migrate/override on load. Horizon's own `Graphics` file is parsed from `Graphics::default()`, so its defaults do apply to missing keys.

### 3.3 Proposed “speed” defaults

```text
render_distance: 8          (from 12)      -54% columns
simulation_distance: 6      (from 12)      -50% ticked chunks
max_fps: 260                (from 120)     removes the 120 cap
vsync: false                (from true)    removes the 60 Hz cap
smooth_lighting: false      (from true)    mesh-time only
clouds: "false"             (from "true")  removes 3-12% cloud cost
cloud_range: 32             (from 128)     16x fewer cells; keeps clouds if re-enabled
particles: 2                (from 0/all)   -50% or more particle work
entity_distance: 0.5        (from 1.0)     halves entity draw range
entity_shadows: false       (from true)    <1%
biome_blend: 0              (from 2)       mesh-time only
graphics_preset: "fast"     (from "fancy") label only; must set the fields above
mipmap_levels: 4            (keep)
weather_radius: 3           (from 10)      49 vs 441 columns
chunk_fade: 0.0             (from 0.75)    cosmetic; avoids fade bookkeeping while streaming
vignette: false             (from true)    one quad in the dark
cutout_leaves: false        (from true)    solid leaves, no alpha test
menu_blur: 0                (from 5)       menus only
```

Horizon graphics file:

```text
entity_culling: async       (from off)
particle_culling: async     (from off)
leaf_culling: hollow        (from off)
blockEntityCache*: true     (from false except signs)
weather: false              (or true with radius 3)
```

**Estimated effect of the full set at 720p/970:** in a forest/rain scene, roughly **+40–100% FPS** (render distance 8, clouds off, particles minimal, leaves solid, weather off), with the largest single contributors being render distance and clouds. In an open, clear, indoor/base scene the gain is smaller (mostly entity distance/culling and render distance). VSync off + 260 can add another 0–100% *displayed* FPS by removing the 60/120 caps. These ranges assume the frame is not limited by simulation/tick on an old CPU; if it is, simulation distance and entity distance matter more.

**Caveat:** `graphics_preset: "fast"` alone is a no-op at runtime. The numeric fields above are what matter. Horizon's built-in `Preset::Performance` (`graphics.rs:1121–1150`) already sets RD 8, simulation 6, clouds off, particles 2, entity shadows off, biome blend 0, mipmaps 0, entity distance 0.5, leaves solid, weather radius 3 — a good starting point, but it does not set VSync/max FPS, cloud range, menu blur, entity/particle/leaf culling or block caches, and its mipmaps 0 is not a speed win.

---

## 4. Deletion candidates ranked by expected FPS gain vs risk

Rank is for a default install at 720p. “Delete” means remove the feature/rendering, not just flip a switch.

| Rank | Deletion | Default | Est. gain | Risk | Verdict |
|---:|---|---|---:|---|---|
| 1 | **Cloud layer** (`clouds.rs`, `cloud_*` paths in `gfx.rs`) | **on**, fancy, 128 chunks | **3–12%** when sky visible; removes rebuild spikes | Low (visual) | **Yes for max speed.** Turning it off captures ~all the gain; deleting the code only removes residual checks. |
| 2 | **Weather** (`weather.rs`, `gfx/weather.rs`, weather draws) | **on**, radius 10 | **3–8%** in rain, 0 clear | Low-medium (visual/gameplay) | **Yes if rain is expendable**; otherwise radius 3–5. |
| 3 | **Particles** (`particles.rs` + geometry) | **all** | **1–5%** typical, **15–30%** heavy | Medium (feedback/visual) | Optional; default 1–2 gets most of it. |
| 4 | **Fancy cutout leaves** (`cutout_leaves`, leaf meshing) | **on** | **3–10%** in forests | Medium (look changes) | Optional; solid leaves are vanilla Fast. `leaf_culling=hollow` is a lesser visual change. |
| 5 | **Block-entity renderers** (`block_entity_render.rs`) | **on** | **1–10%** in bases, 0 elsewhere | **High** (chests/signs/bells vanish) | **No.** Turn caches on instead. |
| 6 | **Entity blob shadows** | **on** | **<1%** | Low | Trivial; not worth a code deletion, but a free default flip. |
| 7 | **Sky** (`sky_base`, celestial, stars) | **on** | **~0.5–2%** (full-screen sky shaded under terrain overdraw) | High (world looks broken) | No. |
| 8 | **First-person hand** | on when held | **~0.1%** | High (no hand/item) | No. |
| 9 | **HUD** | always | **0.1–0.3 ms** | Very high (unusable) | No. |
| 10 | **Screen effects / vignette** | on, mostly skipped | **~0–1%** | Low-medium | No. |
| 11 | **Panorama / menu blur** | title/menus | **0 gameplay**, 0.5–1.5 ms in menus | Low | Menus only; reduce blur passes if menu FPS matters. |

### Already off by default — **not FPS wins**

Deleting these is a code-size/maintenance/risk change, not a frame-time win:

- Distant terrain LOD (`lod_distance: 0`), BlueMap, server-kept far terrain (only constructed when LOD > 0).
- Shader packs, both `shaders/` and Horizon `.hshader` (no pack picked).
- HDR output (`hdr: false`; `hdr_lighting: true` is inert).
- OIT / improved transparency (`improved_transparency: false`).
- GPU culling (`gpu_culling: false`).
- Visibility buffer (`HORIZON_VISBUFFER` unset).
- Frame generation (`FrameGeneration::Off`).
- FXAA, TAA, upscaling (off/native), resolution scale 100%.
- Shader-pack shadows and `shadow_cache` (no pack).
- MSAA — not implemented at all (`docs/graphics.md:114`).
- Mipmap reduction — not a win; keep 4.
- Backend switch — Auto already picks Vulkan; GL is worse.

### Do **not** delete (they save time)

- Section side culling (`sides_on: true`, `gfx.rs:4855`) — drops solid quads facing away from the eye.
- Cave culling (`Graphics::cave_culling: true`) — skips sections behind closed geometry.
- GPU occlusion culling (`gfx/cull.rs`) — self-gating; keep available.
- Translucent batching (`translucent_batching: true`) — 4–16% at RD 32 in its own docs, still positive at 12 over water.
- Entity batching (`gfx/entity_batch.rs`) — one draw per material instead of per model.
- GPU skinning (`gfx/entity_skin.rs`) — moves mob posing to the GPU.
- Packed terrain quads (`packed_quads`, `gfx.rs:4700–4701`) — one 24 B record per quad, ~4× less terrain traffic; enabled by the flat capability, so preserve it if deleting packs.
- Auto upload throttle (`game.rs:591–597`) — already prevents upload bursts.
- Linux submit thread (`gfx/submit.rs`) — +32% FPS in its own measured comment.

---

## 5. Cheap wins that keep the feature

| Win | How | Est. effect | Notes |
|---|---|---|---|
| **Keep clouds, cut range** | `cloud_range: 128 → 32` (`settings.rs:238`); optionally clamp in `clouds.rs:61` | **3–10%** when clouds visible | 16× fewer cells; clouds end at 512 blocks, usually inside fog. Do this even if clouds stay on. |
| **Keep rain, cut radius** | `weather_radius: 10 → 3–5` (`settings.rs:245`) | **0.1–0.4 ms** in rain | 49–121 columns instead of 441. |
| **Keep particles, decrease** | `particles: 0 → 1 or 2` (`settings.rs:239`) | **1–3%** typical | 2 is vanilla “Minimal”; 1 is “Decreased”. |
| **Keep leaves, cull hidden faces** | `leaf_culling: Hollow` (`graphics.rs:793`) | **2–8%** in forests | Smaller visual change than solid leaves; drops only leaf-to-leaf faces. |
| **Keep entities, cull behind terrain** | `entity_culling: Asynchronous`, precheck 64 (`graphics.rs:790–791`) | **0–15%** in mob-dense scenes | Worker-thread queries; stale results leave entities visible. The docs say it is disabled with non-vanilla resource packs (`docs/graphics.md:35`). |
| **Keep particles, cull off-screen** | `particle_culling: Asynchronous` (`graphics.rs:792`) | **0–10%** in farms | Async defers occlusion checks. |
| **Keep block entities, cache settled models** | `cache_shulker_boxes`, `cache_chests`, `cache_bells`, `cache_banners`, `cache_decorated_pots`, `cache_copper_golem_statues` → true (`graphics.rs:794–801`) | **0–5%** in bases | Sign cache is already on. Caches reuse GPU geometry; animations still update. |
| **Keep menu blur, fewer passes** | `menu_blur.rs:15–22`: six `PASSES` → two (horizontal+vertical) | **~3× cheaper menus** | Menu-only; visual blur is less smooth. |
| **Keep AA look, render fewer pixels** | `resolution_scale: 85` or upscaling `Performance` + TAA (`graphics.rs:814–818`) | **15–40%** GPU-bound at 85%; **1.5–2.5×** at upscaling | Softness; at 720p upscaling is aggressive. |
| **Pipeline cache** | Build a `wgpu::PipelineCache` and pass `cache: Some(&cache)` instead of `cache: None` (`gfx.rs:2963, 3206, 3936, 4123, 4237, 4333, 4503, 4575`); persist its data to disk | **Startup only** (potentially 0.5–3 s) | No FPS effect. Useful because `Renderer::new` creates ~80 pipelines eagerly. |
| **Bind group reuse** | Already done: terrain groups once (`gfx.rs:3459–3519`), page groups cached (`flat.rs`), cull group keyed (`cull.rs:561–567`) | 0 | No action; do not “optimise” into per-frame creation. |
| **Smaller formats** | Keep 8-bit frame, RGBA8 atlas/lightmap; do not enable HDR's `Rgba16Unorm` frame | 0 | `Depth32Float` is required for reversed-Z/precision; `Depth24Plus` is usually 32-bit on NVIDIA too. No win. |
| **Fewer render targets** | Already one colour + one depth in the default path | 0 | OIT/HDR/world_post add targets only when enabled. |
| **Disable MSAA** | Already absent | 0 | Nothing to do. |
| **Frustum/occlusion defaults** | Keep `cave_culling`, `section_sides`, section cull; enable entity/particle/leaf culling as above | 0 to +15% | The defaults already have the good ones on (sides/cave/cull). |
| **Upload throttling** | Already auto-limited to 2 ms CPU/frame (6 ms arriving), `game.rs:591–597` | 0 | Setting `chunk_updates`/`upload_budget_kib` non-zero **disables** the time-based auto limiter; only set both after A/B. |
| **Arena compaction budget** | `COMPACT_BUDGET` 32 MiB (`gfx.rs:876`) → 4–8 MiB | p99 improvement while pages close | Not average FPS; reduces hitch size. |
| **Animated textures off** | `animated_textures: false` (`graphics.rs:808`) | **<1%** | Stops per-tick atlas mip uploads for water/lava/fire. Visual loss. |

---

## 6. Exact file:line edit points for the top 10

Line numbers are current at `94ef964`. “Both” rows need both files because `options.txt` missing keys fall back to `options_file.rs`, while a missing file uses `settings.rs`.

| # | Edit point | Change | Est. effect / risk |
|---:|---|---|---|
| 1 | `crates/horizon-client-render/src/settings.rs:222` and `crates/horizon-client-render/src/options_file.rs:165` | `render_distance: 12` → `8` | Largest single win: 625 → 289 columns, ~−54% terrain/streaming work; est. +25–50% FPS. Low risk. |
| 2 | `settings.rs:223` and `options_file.rs:166` | `simulation_distance: 12` → `6` | ~−50% ticked chunks; improves CPU/p99, est. 0–10% avg. Low risk. |
| 3 | `settings.rs:237` and `options_file.rs:163` | `clouds: "true"` → `"false"` | Removes cloud draw + rebuilds; est. +3–12% when sky visible. Low risk (visual). |
| 4 | `settings.rs:238` and `options_file.rs:164` | `cloud_range: 128` → `32` | 171 → 43 cells radius (~16× fewer cells); est. +3–10% if clouds kept; also reduces `depth_far` from 2048 to ~512–768 (`camera.rs:857–858`). |
| 5 | `settings.rs:233–234` and `options_file.rs:156`/`131` | `max_fps: 120` → `260`; `vsync: true` → `false` | Removes 60/120 caps; 0–100% *displayed* FPS depending on headroom; more tearing/latency trade. |
| 6 | `settings.rs:239` and `options_file.rs:161`; `settings.rs:245` and `options_file.rs:170` | `particles: 0` → `2`; `weather_radius: 10` → `3` | Particle workload −50%+; rain columns 441 → 49. Est. +1–5% typical, +3–8% rain. Low risk. |
| 7 | `settings.rs:240–241` and `options_file.rs:132–137` | `entity_distance: 1.0` → `0.5`; `entity_shadows: true` → `false` | Halves entity draw range; removes blob shadow quads. Est. +1–5% typical, +10–30% crowded. Low risk. |
| 8 | `settings.rs:249` and `options_file.rs:130` | `cutout_leaves: true` → `false` | Solid leaves, no alpha test; est. +3–10% in forests. Medium visual. |
| 9 | `graphics.rs:790`, `792`, `793` | `entity_culling: Off → Asynchronous`; `particle_culling: Off → Asynchronous`; `leaf_culling: Off → Hollow` | Terrain/entity/particle culling wins; est. 0–15% scene-dependent. Low-medium. |
| 10 | `graphics.rs:794–801` | block-entity caches `false → true` (shulker boxes, pots, bells, chests, banners, copper-golem statues) | CPU/GPU geometry reuse in bases; est. 0–5%. Low risk. |

**Bonus edits**

| # | Edit point | Change | Effect |
|---:|---|---|---|
| 11 | `settings.rs:254` and `options_file.rs:248` (`menuBackgroundBlurriness`) | `menu_blur: 5` → `0` | Menus lose six full-screen passes; no gameplay change. |
| 12 | `menu_blur.rs:15–22` | `PASSES` 6 → 2 | Keeps a blur, 3× cheaper menus; less smooth. |
| 13 | `graphics.rs:807` | `weather: true` → `false` | Disables rain/snow rendering; +3–8% in rain. |
| 14 | `clouds.rs:61–63` | `let chunks = cloud_range_chunks.min(32);` | Hard cap for players who set 128 while keeping clouds; avoids a hidden 91k-cell blow-up. |
| 15 | `gfx.rs:876` | `COMPACT_BUDGET: 32 << 20` → `8 << 20` | Smaller page-close hitches; no average-FPS change. |

---

## 7. How to verify (without guessing)

1. **Fixed-scene replay:** `cargo run --release -p horizon-client-render --example scene_replay -- <capture> --size 1280x720 --yaw-offsets 0,90,180,270` reports GPU ms/frame, CPU render-call time without waits, per-pass GPU medians, sections and draw calls (`docs/graphics.md:139–158`). A/B `--section-cull`, `--section-sides`, `--section-draws indirect`, `--gpu-culling on`.
2. **In-game:** `HORIZON_SPIKES=8` prints slow frames with CPU/wait split; `horizon-ctl stats` gives avg/1%/p99 frame times. `tools/graphics_bench.py --offscreen` on the 970 at RD 8/12/16 is the closest to the requested target.
3. **A/B the defaults** by editing `options.txt`/`horizon-graphics.txt` rather than rebuilding: render distance, clouds, weather, particles, entity distance, cutout leaves. Then use the same seed/path for each run.
4. **Watch the right counter:** with VSync on, the display caps the number and hides every renderer win. Measure with VSync off and `maxFps=260` first.

---

## 8. Bottom line

For a GTX 970 at 1280×720, the renderer's steady-state cost is already small; the defaults are not. Change render distance 12→8, turn clouds off (or range 128→32), drop simulation distance, halve entity distance, use minimal particles and solid leaves, enable async entity/particle culling and the block-entity caches, and disable VSync/raise the cap. That is roughly a **1.4–2× frame-rate** change in typical outdoor scenes for a handful of one-line edits, without deleting a single renderer subsystem.

The large deletions — LOD, BlueMap, shader packs, HDR, OIT, GPU culling, frame generation, FXAA/TAA — are **already off by default** and buy ~0 FPS. Delete them for maintenance or build time if you like, but do not expect the frame counter to move. Keep the culling, batching, packing, skinning and submit-thread code: those are the parts that already make the renderer fast.
