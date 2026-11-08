# horizon-lite — the per-frame hot path, and what deleting features buys

Read-only static audit of `/home/solenopsisbot/coding/mc/horizon-lite` (Horizon Lite, Rust
Minecraft 26.3 client). No files were edited and no builds were run. Every number below is an
estimate from the code (call counts, loop bounds, allocation sites), not a measurement; the
`--benchmark` harness in `crates/horizon-client/src/benchmark.rs` already records the numbers
needed to confirm them (`fps.<scene>.*`, `cpu_p50_ms`, `gpu_p50_ms`, `gpu_pass.<scene>.hud_ms`).

Frame entry: `Game::render` (`game.rs:13750`) → `render_frame` (`game.rs:13756`), called from
`WindowEvent::RedrawRequested` (`game.rs:16194`). Around it, per frame, `extras_frame`
(`game.rs:16292`), `tick_world_icon` (`game.rs:16297`), `render`, `apply_cursor_icon`
(`game.rs:16307`), and the stats/telemetry tail (`game.rs:16344-16472`). `idle`
(`game/window_handler.rs:120-189`) adds `poll_control` (`:148`) and `poll_pads` (`:152`) before
requesting the next redraw.

Default graphics state matters for every judgement below: `cave_culling` **on**; `gpu_culling`,
`entity_culling`, `particle_culling`, `leaf_culling`, LOD, HDR, frame generation, shader packs
**off** (`horizon-client-render/src/graphics.rs:661-800`). `horizon-extras` (cosmetics, Discord,
Friends, heartbeat) is off in the Lite default build (`horizon-client/Cargo.toml:105-122`), so
most "cosmetic" features already cost one `cfg!` test per frame.

---

## 1. Ordered per-frame cost centres

`U` = unconditional in a normal world frame; `G` = gated by a setting/state (cost only when that
state is on). CPU estimates are for 1080p, render distance 12, clear weather, ~20 loaded entities,
no chat/scoreboard — the quiet case. "Allocs/frame" is heap allocations, not bytes.

| # | Cost centre | Function, file:line | U/G | Work per frame | Est. CPU |
|---|---|---|---|---|---|
| 1 | Terrain visibility, section batching, pass encoding, submit | `Renderer::draw_frame`, `gfx.rs:7807` (called `14513`); `sections.walk` `gfx.rs:8379`; `compact_arena` `6063` | U | Walk ~625 columns at RD12, hash lookups per section; instance/origin buffer rebuild; ~8–12 render passes in one command buffer; 1 `queue.submit` (`gfx.rs:11540`) | 0.8–3 ms |
| 2 | Entity geometry: mobs, items, armour stands, block entities, name tags, shadows, hand | `entity_geometry`, `game.rs:9572` (call `14233`); `mob_geometry_inner` `creatures.rs:7509`; BE list `game.rs:9882-9970`; `hand_geometry` `12700` (call `14280`) | U | Iterates every mob (each renders a model into `Vec<Vertex>`), every dropped item, every visible block entity; dozens of `Vec`s (`camera_list`, `shadow_only`, `HashSet`s, `see_through`); 0 shadow culling by default | 0.5–2.5 ms |
| 3 | HUD batch build (crosshair, hotbar, health/food/air, exp/locator, effects, boss, chat, tab list, scoreboard, titles, toasts) | `Game::hud` `game.rs:7844`, `hud_layers` `7875`; `hud_layout::paint` `hud_layout.rs:792` | U | ~20 `gui_layer` closures, 20+ `Vec<GuiDraw>` allocations, `paint` allocates a pose-stack `Vec` each call (`:793`); 9 hotbar item models resolved + 9 decoration `Vec`s; text laid out glyph-by-glyph | 0.15–0.8 ms |
| 4 | Particle extract | `ParticleEngine::render`/`render_culled`, `particles.rs:4651/4675`, called `game.rs:10249/10269` | U | Loops every particle (cap 16384, `particles.rs:1300`), builds camera-facing quads, light lookup per section | 0.05–1.5 ms (count-dependent) |
| 5 | HUD vertex/uniform upload | `Renderer::draw_frame` `gfx.rs:9556` → `HudBatch::prepare` `hud.rs:2843` | U | Copies the whole `batch.vertices` (20–400 KB) + uniform into the upload belt every frame | 0.02–0.1 ms |
| 6 | Weather geometry | `weather_geometry`, `game.rs:13124` (call `14306`) | G (weather on, raining) | `(2r+1)²` columns (r=3 default, 49), each `rain_height` + biome + `world.light` + 1–4 quads | 0.03–0.2 ms (0 clear) |
| 7 | Chat / scoreboard text | `Chat::layout` `chat.rs:715`/`draw` `846` (call `game.rs:8208`); `sidebar` `hud_overlays.rs:634`, `draw_scoreboard` `scoreboard.rs:800` | G (message/board present) | Chat: 2 `Vec`s + one `Text` clone per visible line (`chat.rs:752,790`). Sidebar: `list_scores` clones **every** holder (`scoreboard-core/scoreboard.rs:939`), `java_sort`, per-row `Text` + `resolve_legacy` clones, `width()` twice | 0.05–0.5 ms |
| 8 | Font/text rendering internals | `HudBatch::text` `hud.rs:2034` → `text_styled` `2052` → `styled_text` `2115`; `Text::literal` `text.rs:191`; `bidi::visual` `bidi.rs:269` | U (embedded in #3/#7) | Every plain string becomes a `Text` **with a `serde_json` object** (`json!({"text": …})`), then `styled_text` allocates a `Vec` of 11-field glyph tuples per call (`hud.rs:2133`), scans chars for RTL first, then draws all shadows and all glyphs in two passes | 0.05–0.3 ms + ~2–4 allocs per text call |
| 9 | Hotbar item decorations | `draw_item_decorations` `inventory_slots.rs:116`; `item_decorations` `hud_overlays.rs:737` | U when an item is held | Per slot: `count.to_string()`, `Text::literal`, 3 `Vec<GuiDraw>`, a `paint` call (another `Vec`) | 0.05–0.2 ms, ~36 allocs |
| 10 | Item model resolution (hotbar + hand) | `draw_item_model` `item_draw.rs:387`; `resolve_item_in_hand` `:330`; `resolve_with_rule` `item_render.rs:899` | U | Re-resolves model layers (`Vec<LayerRender>`) for each drawn stack every frame; GUI items animate | 0.05–0.25 ms |
| 11 | Biome colour probe | `world_biomes!` + `gaussian_weights`, `game.rs:13966-13975`, `biome.rs:470` | U | 6×6×6 = 216 quarters, each a chunk hash lookup + `biome()`; `Vec` of weights; 3 `blend_rgb` passes | 5–20 µs |
| 12 | Shader-pack selection & paths | `shader_pack_inputs`, `shader_packs.rs:201` (call `14324`) | U | `picked_pack(...).to_owned()`; `shader_packs_dir()` → `game_dir()` → **`std::env::current_dir()` syscall** (`options.rs:101`); `resolve_path` clone (`native_shaders.rs:35`); `follow_packed_layout` calls `std::env::var("HORIZON_PACKED_QUADS")` (`gfx.rs:156,6407`) | 2–10 µs + 2–4 allocs + 1 syscall |
| 13 | Extras frame (FPS/CPS bookkeeping, minimap, PvP globals, recipes) | `extras_frame`, `game/extras.rs:53`; `update_minimap` `:166`; `pvp_frame` `game/pvp.rs:180` | U | `FpsCounter::record` (VecDeque push), native-hook dispatch, two `Option` probes; minimap scan only with a mod (`MINIMAP_BUDGET = 300 µs`, `extras.rs:31`) | 2–10 µs; **up to 300 µs with minimap** |
| 14 | Minimap compose/upload | `Minimap::update` `minimap.rs:280`, `compose` `:329`, `map_patches.push` `game/extras.rs:208` | G (minimap on) | 128×128 pixel loop + 64 KB `image.clone()` + 64 KB atlas patch texture upload on change | 0.02–0.1 ms on compose |
| 15 | PvP & HUD widgets | `draw_pvp_hud`, `game/pvp.rs:249` | G (`hud.any()`, all off by default, `pvp.rs:607`) | Armour array (4 `Arc` clones), per-widget equality checks; text rebuilt only on change | 10–100 µs when on |
| 16 | Debug overlays/charts | `draw_debug_overlay_under` `debug_keys.rs:309`; `debug_gizmos` `:992`; `debug_renderer_geometry` `debug_renderers.rs:102`; `DebugCharts::draw` `debug_chart.rs:167/262` | G (F3) | F3 closed: `any_enabled` + ~5 `debug_entry` lookups. Open: lines formatted/painted 20×/s (`REPAINT` `debug_overlay.rs:22`), vertices copied in between, chart geometry | 1–5 µs closed; 0.1–0.3 ms open |
| 17 | Performance overlay | `FrameGraph::record` `perf_overlay.rs:18` (call `game.rs:16348`), `draw` `:25` (call `7870`) | record U; draw G (`Overlay::Off`) | Record: one `VecDeque` push. Draw: 3 `format!`s, 3 text layouts, 160 bars × 2 fills + lines | record <1 µs; draw 0.03–0.1 ms |
| 18 | Frame stats / session telemetry / crash tick | `FrameStats::record*` `game.rs:16357-16368,16422`; `telemetry::Session::frame` `telemetry.rs:257` (call `16434`); `debug_charts.frame_times.log` `16423`; `debug_crash_tick` `16457` | U | 3–4 `Vec` pushes into 1M-entry histories (`control.rs:669`), timing bins, ring-buffer log, `OnceLock` check | 2–8 µs |
| 19 | GPU timer (timestamp queries + `device.poll`) | `GpuTimer::{begin,end,collect}`, calls `gfx.rs:9658,11428,11565`; created unconditionally `gfx.rs:2781` | U | 2 timestamp writes + resolve + 16-byte copy; `device.poll(Poll)` every frame | 5–30 µs + GPU query overhead |
| 20 | Control/agent/repro/narrator/toasts | `poll_control` `game/control.rs:186`; `advance_agent` `game/agent.rs:1864`; `poll_repro` `game/repro.rs:382`; `narrate_screen` `game/narrator.rs:244`; `draw_toasts` `advancements.rs:2083` etc. | U | `try_recv`, Option checks, `widgets::end_frame` (6 thread-local swaps), empty toast loops | 5–50 µs (narrator active: more) |
| 21 | Studio freecam/replay | `advance_studio_replay` `game/studio.rs:453`; `render_camera_path` `studio/path_render.rs:18`; freecam check `game.rs:16207` | G | Idle: two `Option` tests. Playing: packet dispatch + spline sampling per frame | ~0 idle; 0.1–2 ms replaying |
| 22 | Screen quads / camera overlays | `screen_quads`, `game/render_tick.rs:260` (call `14298`) | U | 8 eye-block tests, 2 `fog_type` walks, small `Vec` | 3–15 µs |
| 23 | Audio listener | `Audio::set_listener` `audio.rs:1283` (call `game.rs:13931`) | U | Locks the mixer mutex every frame | 1–3 µs |
| 24 | HUD atlas bookkeeping | `GuiAtlas::pack_pixels` `hud.rs:811` (call `13762`), `font.begin_frame` `font.rs:796` (`13766`) | U | Early-outs once packed / region not full | <1 µs |
| 25 | Native hooks with no mods | `observe_screen` `native_hooks.rs:1130`, `native_frame` `:2317`, `native_hud` `:2642`, `native_minimap_now` `:12361`, `dispatch_*` | U | Each dispatch iterates an empty mod list; event structs built anyway | 2–10 µs |
| 26 | World streaming/update | `update_world` `game.rs:14679`, `streaming.update` `:14748`, uploads `:14855-14923` | U | Core: chunk I/O, meshing, uploads; optional LOD path returns when `lod_distance == 0` | 0.2–1 ms (scene-dependent) |

GPU submits per frame: normally **one** (`queue.submit_later`, `gfx.rs:11540`); a second when
section copies/atlas patches have to go out on a frame that was not drawn (`gfx.rs:7709-7727`).
Inside that one command buffer there are ~8–12 render passes (sky, solid, cutout, translucent,
entities, particles, block entities, weather, hand, screen effects, HUD, optional blur). The HUD
itself is 1–2 passes (`HudBatch::draw_range`, `hud.rs:2912`).

---

## 2. Which optional features can actually be deleted

"Cost today" is the steady-state cost **as configured by default**; most are already off.

| Feature | Code | Cost today | Verdict |
|---|---|---|---|
| Cosmetics / emotes | `game/cosmetics*` 7.4k LOC; `CUTS.tsv` p2 | `cfg!(feature="horizon-extras")` false (`cosmetics.rs:439`), plus `cosmetics_frame` call from `flush_skin_slots` (`scoreboard.rs:830`) | **Delete for code size, not speed.** ~0 µs/frame in Lite. If enabled: presence/owner checks every frame in `cosmetics_frame` (`cosmetics.rs:446-560`), per-mob `worn()` lookups in `cosmetics_fx_geometry`. |
| Extras HUD (FPS/CPS/coords/keys/clock/armour/effects) | `game/pvp.rs`, `pvp_hud.rs`, `render/extras.rs` | `hud.any()` false by default (`pvp.rs:607`); one probe per frame | **Near-zero win when off**; 10–100 µs when on. Deleting removes a large settings page, not frame time. |
| Minimap | `minimap.rs`, `game/extras.rs:144-215`, `extras_hud.rs:59`, `MINIMAP_SPRITE` | 0 unless a native mod returns a minimap; then **up to 300 µs/frame** scanning 16×16×height columns (`scan_tile`, `minimap.rs:156`), 1 Hz re-scan per edited chunk, plus compose + 64 KB upload | **Real win only if the mod/minimap is used.** Best delete candidate among the "extras": bounded 300 µs budget, self-contained. |
| PvP HUD | `game/pvp.rs:249` | 0 when all widgets off; well cached when on | **Keep; deleting buys ~0.** |
| Studio recorder / replay / freecam | `game/studio.rs`, `src/studio/` | Idle: 2 `Option` checks in `update_world`/RedrawRequested | **No per-frame win.** Active replay is expensive but that is the feature. |
| Agent / control socket / repro / tick script | `game/agent.rs`, `control.rs`, `repro.rs`, `tick_script.rs` | Control socket off unless `--control` (`game.rs:634,843`); idle ~5–20 µs for `poll_control`/`advance_agent`/`poll_repro` | **Delete for attack surface/code, not frame time.** When enabled, `watch_events` traces every input event. |
| Debug overlays / charts | `debug_keys.rs`, `debug_chart.rs`, `debug_overlay.rs` | 1–5 µs when F3 closed; 0.1–0.3 ms when open | **Keep gated.** Delete only if the user never presses F3. |
| Replay recording (repro) | `game/repro.rs` | ~0 idle; recording keyframes are tick-time work | **No per-frame win.** |
| Narrator | `game/narrator.rs`, `screen_narrator.rs` | `narrate_screen` + `frame()` every frame; inactive path ~1–2 µs; active path does widget diffs | **No meaningful win.** |
| Toasts (advancement/tutorial/pack/music/narrator) | `advancements.rs:2083`, `tutorial.rs:490`, `server_packs.rs:542`, `music.rs:124`, `narrator.rs:277` | 5 empty loops + `toast_slots_used` per frame, ~2–5 µs | **No win.** |
| Screenshots / recording | `tick_world_icon` `game.rs:13699`; `renderer.screenshot` `gfx.rs:7741`; `capture_glint_frame` `item_draw.rs:405` | ~1–3 µs idle (the world icon stops after its one shot) | **No win**; keep the one-shot guards. |
| Telemetry | `telemetry.rs:257`, `game.rs:17609` | Default (no consent): timing-bin updates ~2 µs. Consent on: `record_here(true)` makes every `spans::time`/`guard` in the frame push a `Span` and read an `Instant` (~50–80 spans) | **Worth turning off for max speed** (and it is the honest "no telemetry" Lite story): ~20–150 µs/frame, plus `take_raw` allocation. |
| Weather / clouds / sky / celestial | `game.rs:14305,13124`, `custom_sky_frame`, `celestial_geometry` | Weather radius 3 = 49 columns; clouds/sky/celestial always built in Overworld | **Biggest true "feature deletion" win after particles**: rain geometry 0.03–0.2 ms + rain particles, cloud pass. |
| Particles | `particles.rs:4651`, call `game.rs:10249` | 0.05–1.5 ms; **particle culling is off by default** (`graphics.rs:792`) | **Turning off particle rendering (or enabling culling) is a top-tier win.** Deleting the engine removes splash/smoke/dust, i.e. a visible vanilla feature. |
| Entity shadows | `entity_geometry` `game.rs:9784-9852` | Per-entity shadow geometry, `mob_casters` Vec | Medium win with many mobs; `entity_shadows=false` is a one-line setting. |
| HUD text overlays (chat/scoreboard) | see §1 #7 | 0.05–0.5 ms on servers | Not a "feature to delete", but the cheapest large HUD win is caching, not removal. |

**Bottom line:** deleting the headline optional product features (cosmetics, Studio, agent,
replay, narrator, toasts, screenshots, telemetry plumbing) buys **well under 0.1 ms/frame**
combined. The only optional features with real per-frame cost are the **minimap (when used)**,
**PvP/FPS widgets (when on)**, **F3/perf overlay (when on)**, and the "vanilla-optional" content
rendering: **particles, weather, clouds, entity shadows**.

---

## 3. Per-feature saving, risk, effort

| Feature deletion | Work removed / frame | Risk | Effort |
|---|---|---|---|
| Minimap + native minimap hook | ≤300 µs scan + compose (0.02–0.1 ms when it recomposes) + 64 KB upload | Low (mod-only API) | 2–4 h (`extras.rs`, `minimap.rs`, `extras_hud.rs`, `hud.rs` sprite, `native_hooks.rs:12361`) |
| PvP HUD + extras widgets | 10–100 µs when enabled; ~1 µs when off | Low | 4–8 h (large settings surface; `CUTS.tsv` says 12 h) |
| Studio recorder/replay/freecam | ~0 idle; 0.1–2 ms only while replaying | Low | 4–6 h |
| Agent/control/repro/tick-script | 5–20 µs idle; input tracing per event when on | Low | 8–12 h (many call sites) |
| Debug overlay/charts | 1–5 µs idle; 0.1–0.3 ms with F3 open | Low | 2–3 h |
| Narrator | 1–2 µs idle; ~0.05 ms active | Low (accessibility feature) | 2–4 h |
| Toasts | 2–5 µs | Low | 2 h |
| Screenshots/recording | 1–3 µs | Low | 1–2 h (keep the world-icon path or remove `save` UI) |
| Telemetry (`Session`, `record_here`) | 2 µs default; 20–150 µs if consent is on; also stops per-frame span `Vec` growth | Low | 1–2 h |
| Cosmetics/emotes | ~0 in Lite default; presence checks when enabled | Low–med | 8–10 h |
| Weather + rain particles | 0.03–0.2 ms geometry + proportional particle cost | Med (visible content) | 2–4 h (or one setting) |
| Particles | 0.05–1.5 ms | Med (visible content) | 1 h as a setting; 3–5 h to delete the engine |
| Entity shadows | 0.1–1 ms with many entities | Low (setting exists) | 1 h as a setting |
| Clouds | 0.05–0.3 ms GPU + per-frame input build | Low | 1–2 h |

---

## 4. Per-frame waste that exists even in upstream

These are wins with **no feature removed**. Ordered by likely value.

1. **`Text::literal` allocates a `serde_json` object per text draw** — `text.rs:191-202`
   (`source: Some(json!({"text": text}).into())`) plus a `String` and a `Span`. `HudBatch::text`
   (`hud.rs:2034`) calls it for every plain string, every frame (item counts, overlay text,
   scoreboard/chat builders). A `&str` fast path (no `source`, borrowed span) removes ~2–3
   allocations per call.
2. **`styled_text` allocates a glyph `Vec` per text call** — `hud.rs:2133`, tuple of 11 fields
   per character. Reusing a thread-local scratch `Vec` (cleared per call) removes 30–100 KB/frame
   of allocator churn with F3/chat/scoreboard open; it also runs `bidi::visual` (`bidi.rs:269`)
   which scans every char to discover the text is LTR.
3. **Sidebar scoreboard clones the whole board and sorts it every frame** —
   `hud_overlays.rs:634-709`, `list_scores` `horizon-client-core/src/scoreboard.rs:939` (`owner.to_owned()`,
   `display.clone()`, `number_format.clone()` for **all** holders, not just the 15 shown), then
   `formatted_name` + `resolve_legacy` + two `width()` measurements per row. Cache `Vec<GuiDraw>`
   keyed by a scoreboard revision (add a counter bumped by the scoreboard packet handlers).
   Zero visual change; easily 100+ allocations and a sort per frame on servers.
4. **Chat layout clones the `Text` of every visible line and rebuilds two `Vec`s per frame** —
   `chat.rs:715,752,790`. `GuiDraw::Text` owns `Text`, so change it to borrow or cache the laid-out
   `Vec<GuiDraw>` until (ticks, scroll, focus, width) change.
5. **`hud_layout::paint` allocates a pose stack `Vec` on every call** — `hud_layout.rs:792-793`.
   Called 20+ times/frame (each GUI layer, each hotbar item, each chat/effect batch). Use a small
   fixed array (pose depth is tiny) or a reusable buffer.
6. **Hotbar decorations rebuild everything per slot per frame** — `inventory_slots.rs:116-137` and
   `hud_overlays.rs:737-761`: `count.to_string()`, `Text::literal`, 3 `Vec<GuiDraw>`, another
   `paint` stack, per slot. Cache the `GuiDraw` list per (item, count, damage, cooldown) or draw
   in one shared `Vec`.
7. **`current_dir()` syscall + `env::var` every frame** — `game_dir()` (`options.rs:101`) via
   `shader_packs_dir()` (`:105`) from `shader_pack_inputs` (`shader_packs.rs:201`), and
   `packed_wanted()` (`gfx.rs:156`) called from `follow_packed_layout` (`gfx.rs:6405`). Cache both
   in `OnceLock`; also stop `.to_owned()`/`PathBuf::clone()` in `shader_pack_inputs` and
   `resolve_path` when the selection did not change.
8. **The whole HUD is rebuilt and re-uploaded while paused or on a static screen** —
   `hud()`/`hud_layers` (`game.rs:7844/7875`) → `HudBatch::prepare` (`gfx.rs:9556`). Menus redraw
   at full frame rate; the batch is identical unless the cursor moved. Cache the batch (or the
   `Vec<GuiDraw>` layers) keyed by cursor/screen/size/selection and re-upload only on change.
9. **`requested_post_effects` allocates a `Vec<String>` + `String` every frame** —
   `screen_backgrounds.rs:90-98`. If the resource set lacks `post_effect/end_of_frame.json` the
   chain load fails once and the copies are skipped, but if the pack **does** supply it,
   `PostEffects::apply` (`post_chain.rs:1119`) performs two full-frame texture copies and two
   fullscreen blits even for a zero-pass chain (`:1193,1219-1236`). Skip chains whose
   `passes.is_empty()` (verify first): that is pure bandwidth, 0.1–0.5 ms at 1080p.
10. **Frame statistics nobody consumes** — `FrameStats::record/record_cpu/record_phases`
    (`game.rs:16357-16368,16422`) push into 1M-entry `Vec`s (`control.rs:669`), and
    `debug_charts.frame_times.log` (`16423`), `Session::frame` (`telemetry.rs:257`) and the GPU
    timestamp timer (`gfx.rs:9658/11428/11565`, including `device.poll`) run every frame. Gate
    them behind `--control`/`--benchmark`/overlay/F3 or the perf consent. Saves 10–40 µs CPU,
    avoids a per-frame `device.poll`, and stops ~24 MB of history growth.
11. **Per-frame effect icons** — `hud_overlays::effects` (`hud_overlays.rs:138-200`) sorts the
    effect list, allocates a sprite `String` per effect, formats the duration text every frame.
    Cache the draws until (tick, effects) changes.
12. **`flush_skin_slots` runs before the tab-list visibility gate** — `scoreboard.rs:839` calls it
    every frame even when the list is not shown; `update_remote_skins`/`publish_tab_object_skins`
    also run. Move the flush behind `tab_players_needed`/skin demand.
13. **Minor but free:** `HudBatch::new(size)` inside `render_frame` just to read `.scale`
    (`game.rs:14057`); `world_biomes!`'s 216 chunk lookups (`13966`); duplicate `fov_degrees`
    calls (`14156`, `14451`, `render_tick.rs:277`); `settings.file.*` hash lookups in the frame
    (`13775` etc.); `HudBatch::runs()` allocating twice per frame in `draw_range`
    (`hud.rs:2938`).
14. **`spans` recording**: with telemetry consent, ~50–80 `Instant::now()` + `Span` pushes per
    frame (`spans.rs:88-117`). Turning it off is worth more than deleting several optional
    features.

---

## 5. Top 10 frame-time changes

Impact is for the quiet default scene unless stated; "evidence" is the code path above.

| # | Change | Impact | Evidence / exact edit point |
|---|---|---|---|
| 1 | **Enable the culling that is off by default** (`particle_culling`, `entity_culling`, `gpu_culling`) — no content removed | **High** in dense/busy scenes (particles 0.05–1.5 ms, entity geometry 0.5–2.5 ms) | Defaults `graphics.rs:789-793`: `gpu_culling: false`, `entity_culling: Off`, `particle_culling: Off`; consumers `game.rs:10247-10282`, `creatures.rs:7490-7506`, `gfx.rs:8307-8362` |
| 2 | **Delete/disable the minimap and its 300 µs scan** | **High if used**, zero if not | `game/extras.rs:31` (`MINIMAP_BUDGET`), `:166-215`; `minimap.rs:156,280,329`; `extras_hud.rs:59`; `native_hooks.rs:12361` |
| 3 | **Skip particle extraction (or delete the particle engine)** | **High** in rain/smoke/fire scenes | `game.rs:10244-10283`; `particles.rs:4651-4703`; cap `particles.rs:1300` |
| 4 | **Cache the scoreboard sidebar draws on a revision** | **High on scoreboard servers** (0.1–0.5 ms, 100+ allocs/frame) | `hud_overlays.rs:634-709`; `scoreboard.rs:800-815`; `list_scores` `horizon-client-core/src/scoreboard.rs:939` |
| 5 | **Make text drawing allocation-free**: `&str` fast path in `HudBatch::text`, drop `serde_json` from `Text::literal`, reuse the glyph scratch `Vec`, skip bidi scan for ASCII | **Medium–high** with chat/scoreboard/F3 (0.05–0.3 ms, hundreds of allocs) | `hud.rs:2034,2052,2115,2133`; `text.rs:191-202`; `bidi.rs:269-287` |
| 6 | **Disable weather + rain particles** (feature removal) | **Medium–high when raining** (0.05–0.3 ms + particles) | `game.rs:14305` (gate), `13124-13202` (geometry); `settings.weather_radius` default 3 `settings.rs:247` |
| 7 | **Reuse the HUD batch / skip rebuild while paused or static** | **Medium in menus**; small in play | `game.rs:7844,7875`; `HudBatch::new` `hud.rs:1693`; upload `gfx.rs:9556`; pause `screens.rs:238` |
| 8 | **Cache chat layout and effect-icon draws** | **Medium on chat-heavy play** | `chat.rs:715,752,790,846`; `hud_overlays.rs:138-200`; `potions.rs:2134-2146` |
| 9 | **Remove per-frame syscalls/path work in shader-pack selection** | **Low–medium (fixed 2–10 µs + lock contention)** | `shader_packs.rs:201-260`; `options.rs:101,105`; `gfx.rs:156,6405`; `native_shaders.rs:35-56` |
| 10 | **Gate frame stats, GPU timer, frame graph, telemetry, and the post-effect chain when unused** | **Low CPU (10–40 µs), stops `device.poll` + timestamp queries; ~24 MB RSS** | `game.rs:16348-16468,16422`; `gfx.rs:2781,9658,11428,11565`; `telemetry.rs:257`; `post_chain.rs:1119,1193-1236` with `screen_backgrounds.rs:90-98` |

Honourable mentions (low risk, easy): cache hotbar item decorations (`inventory_slots.rs:116`),
make `hud_layout::paint`'s pose stack fixed-size (`hud_layout.rs:792`), cache `shader_packs_dir`
and `picked_pack`, skip `flush_skin_slots` when the tab list is hidden (`scoreboard.rs:839`),
cache `fov_degrees` once per frame, and gate `pvp_frame`/`native_frame` on their features.

---

## 6. What to measure before/after

Use `--benchmark standard --offscreen` and compare, per scene, `fps.*.avg_fps`,
`fps.*.low_1pct_fps`, `cpu_p50_ms`, `gpu_p50_ms`, and `gpu_pass.<scene>.hud_ms` (the HUD pass
time is recorded explicitly; `benchmark.rs:123-150`). For CPU attribution run with `HORIZON_SPIKES`
(`spans`), or `horizon-ctl`'s `bench`/`status` `frames.phases_avg_ms` / `frames.slow_phases_avg_ms` (`control.rs:763-784`), which
splits `update`, `tick`, `prepare`, `render`. The harness itself is not part of the hot path in
normal play: `benchmark::start` only spawns its driver thread with `--benchmark`
(`benchmark.rs:79-91`), and the control socket only exists with `--control` (`game.rs:634,843`).

Caveat repeated: the millisecond figures are static estimates; the ordering (terrain/entities/
particles → HUD → gated extras → telemetry) is what the code supports, and the benchmark fields
above will turn them into facts on this machine.
