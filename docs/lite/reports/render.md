# Horizon Lite — Rendering & Graphics slice

**Source:** `/home/solenopsisbot/coding/mc/horizon-src` (read-only)
**Scope:** `crates/horizon-client-render/` (223,162 LOC / 277 `.rs` + 6,201 LOC / 33 `.wgsl`) plus graphics glue in `crates/horizon-client/src` (`game/render_tick.rs`, `game/screen_backgrounds.rs`, `item_render.rs`, `first_person.rs`, `game/native_*_draw.rs`, `game/occlusion_culling.rs`, `game/particle_culling.rs`, `game/shader_packs.rs`, `game/native_shaders.rs`, `game.rs::render_frame`) and the graphics crates `horizon-shaders`, `horizon-optifine`, `horizon-shader-api`, `horizon-hdr`.
**Whole workspace:** 1,328,595 LOC of `.rs`. This slice is therefore **~21%** of the tree — ≈280k LOC counting `.wgsl`, client glue and the four graphics crates.

### Headline numbers

| | |
|---|---|
| Render crate | 223,162 LOC (28% of it tests: 1,753 `#[test]` fns, ~63k LOC inside `mod tests`) |
| `gfx.rs` alone | 15,008 (≈2,100 tests, ≈1,600 shader-pack plumbing, ≈900 HDR, ≈600 splitscreen, ≈400 GPU culling) |
| `gfx/` submodules | 58,246 |
| Shader-pack code (both formats) | 22,944 in-crate + `horizon-shaders` 21,204 + `horizon-shader-api` 4,216 = **48,364** |
| LOD / far terrain / BlueMap | 12,478 in-crate + `lod_net` 1,241 = **13,719** |
| OptiFine resource-pack features | 5,724 in-crate + `horizon-optifine` 11,299 = **17,023** |
| HDR | 1,912 in-crate + `horizon-hdr` 330 = **2,242** |
| Cargo features gating any of this | **none** — the only feature in the render crate is `audio` (39 sites); `horizon-extras` gates client-side cosmetics/Discord/friends, *not* graphics |

Everything graphical is unconditional today. That is the single most important fact in this slice: none of these cuts are behind a flag, so every one is a delete-and-compile exercise.

---

## 1. Subsystem table

LOC excludes `.wgsl` unless noted. "Impact" = change to a **default** install's pixels/behaviour.

| # | Subsystem | Files | LOC | Verdict | Vanilla-look impact | Risk | Exact edit points |
|---|---|---|---|---|---|---|---|
| 1 | Terrain section renderer (arena, resident, upload, submit, hold, page_runs, view, reuse, translucency, animate, `terrain.wgsl`) | `gfx.rs`, `gfx/{arena,resident,submit,hold,page_runs,view,reuse,translucency,upload,animate,flat}.rs`, `terrain.wgsl` | ~21,000 | **CORE** | none | low | keep; `Renderer::new`/`render`/`draw_frame` in `gfx.rs` are the surgery site for everything else |
| 2 | Section occlusion graph (vanilla `SectionOcclusionGraph`) | `gfx/occlusion.rs` | 1,796 | **CORE** | none (vanilla) | low | keep; `Occlusion::{update,reach,visible_for_camera}` |
| 3 | GPU depth occlusion culling (**Horizon perf extra**, on by default) | `gfx/cull.rs`, `gfx/cull.wgsl` | 893 | **GATE** | none (conservative, pixel-identical) | low | `Renderer.cull` field, `cull::Cull::{new,supported}`, `occlusion_culling_requested`, `graphics_ui` "Culling" group |
| 4 | Entity/material batching, outlines, GPU skinning | `gfx/{entity_batch,entity_outline,entity_skin,world_text,fluid,pack_draw}.rs`, `entity.wgsl`, `static_entity.wgsl`, `entity_skin.wgsl` | 2,139 | CORE (skin = **GATE**) | none | **med** — GPU skinning is default-on and must fall back to the CPU path exactly (`Renderer::skins_entities`, `mobs/render.rs`) |
| 5 | Sky, stars, end sky, sunrise fan, clouds, weather, fog | `clouds.rs`, `fog.rs`, `weather.rs`, `gfx/{weather,stars,end_sky,sunrise_fan}.rs` | 3,095 | **CORE** | none | low | keep; `sky`/`fog`/`weather` booleans already exist in `graphics.rs` |
| 6 | Particles | `particles.rs`, `particles/native.rs` | 6,035 | **CORE** | none | low | keep; `hideBlockBreakParticles` is an extras flag inside `particles.rs` |
| 7 | Block-entity renderers (+7 model caches, off by default) | `block_entity_render.rs`, `block_entities.rs`, `block_entity_anim.rs`, `*_tests.rs` | 8,338 | **CORE** (caches **GATE**) | none | low | `graphics.{cache_shulker_boxes,cache_signs,…}` — the cache branches are interleaved through `block_entity_render.rs`, not a separable module |
| 8 | HUD (hotbar, chat, boss bars, subtitles, effects) | `hud.rs`, `hud/`, `hud_layout.rs`, `hud_overlays.rs` | 8,281 | **CORE** | none | low | keep |
| 9 | Font, widgets, screens, panorama, menu blur, world border | `font.rs`, `ui.rs`, `widgets.rs`, `screen_draw.rs`, `screen_effects.rs`, `menu_blur.rs`, `gfx/panorama.rs`, `border_render.rs` | ~9,000 | **CORE** | none (all vanilla 26.3) | low | keep |
| 10 | Settings UI | `options_ui.rs`, `graphics_ui.rs`, `settings_shell.rs`, `settings.rs`, `graphics.rs`, `graphics_style.rs` | 18,282 | **CORE / REWRITE** | none | **med** — `graphics_ui::rows()` must lose the Shaders/HDR pages; `Page` enum at `graphics_ui.rs:23` |
| 11 | **LOD / distant terrain** | `lod.rs`, `lod/{mesh,cache}.rs`, `gfx/lod.rs`, `terrain_model.rs(+tests)` | 8,920 | **CUT** | none (off by default: `lodDistance: 0`) | med — 22 levels, worker threads, `Renderer::clear_lods`, `Game::{prepare_lod,clear_lod}` |
| 12 | **BlueMap far-terrain import** | `bluemap.rs`, `bluemap_detect.rs` | 2,561 | **CUT** | none | low | `bluemap::Settings` (field of `graphics::Graphics`), `bluemap_detect::source`, `Game.lod_blue_map` (`game.rs:2453,14617`) |
| 13 | Server-kept far terrain / Bobby | `server_terrain.rs` | 997 | **CUT** | none | low | `terrain::ServerTerrain`, `game.rs:14670` |
| 14 | **OptiFine/`shaders/` shader packs** | `gfx/pack_*.rs` (56 files), `post_glsl.rs`, crate `horizon-shaders` | 22,944 + 21,204 | **CUT** | none (no pack picked) | **high** — ~150 branch sites in `gfx.rs`; `PickedPack` shapes vertex layout |
| 15 | **Horizon `.hshader` packs** | `gfx/native_*.rs`, `gfx/{displace,block_light,wgsl_prefix}.rs`, `native_emissive.rs`, `shader_ui.rs`, `shader_options.rs`, `shader_pack_list.rs`, crate `horizon-shader-api` | 9,239 + 4,216 | **CUT** | none | high | `Renderer::set_native_shader_pack` (7201), `native` field (1500) |
| 16 | **HDR** | `gfx/{hdr,hdr_icc,hdr_stats}.rs`, `hdr_calibration.rs`, `hdr.wgsl`, `hdr_stats.wgsl`, crate `horizon-hdr` | 1,912 + 330 | **CUT** | none (off by default) | **high** — `frame_format()` and `EMISSION_BITS` | `Renderer.hdr`, `frame_format` (2121), `graphics.hdr*` (735-779), `Page::Hdr` |
| 17 | **GPU culling** | `gfx/gpu_culling.rs`, `gpu_culling.wgsl` | 3,446 + 523 wgsl | **CUT** | none (off by default) | med — deep in `draw_frame` | `graphics.gpu_culling` (676), `Renderer::gpu_*`, `HORIZON_GPU_CULL` |
| 18 | **Splitscreen** | `split_{layout,map,ui,profiles}.rs`, `split_profiles/store.rs`, `gfx/compositor.rs` | 3,626 | **CUT** | none (single player) | med | `gfx::compositor`, `gfx/view.rs` `MAX_VIEWS = 2`, `Game.splitscreen` |
| 19 | **Frame generation (FSR 3.1)** | `gfx/frame_gen.rs`, `gfx/frame_gen/{interpolation,optical_flow,motion}.rs` + wgsl | 2,442 | **CUT** | none (off by default) | med | `graphics.frame_generation`, `fg_frames`, present thread |
| 20 | **OptiFine resource-pack features** (CTM, CEM, CIT, custom sky, Fusion, emissive) | `connected.rs`, `cit*.rs`, `block_entity_cem.rs`, `fusion.rs`, `custom_sky.rs`, `gfx/custom_sky.rs`, crate `horizon-optifine` | 5,724 + 11,299 | **CUT** (or GATE) | none without a pack | **med** — hooks sit in `mesher.rs`, `hud.rs`, `block_entity_render.rs`, `models/` | `assets.rs:348` (`fusion::load`), `mesher.rs:1868` (`fusion.pick`), `mobs/cem.rs`, `mobs/render.rs` |
| 21 | Resource-pack browser + pack screen | `pack_screen.rs`, `pack_browser.rs` | 2,607 | **GATE** | none | low | `options_ui::Page::ResourcePacks`, `Mods → Shader packs` tab |
| 22 | Vanilla `post_effect` chains | `post_chain.rs`, `post_glsl.rs`, `post_chain.wgsl` | 2,651 | **CORE** (GLSL path GATE) | **yes if cut** — creeper/spider/invert spectator vision is vanilla | med | `post_chain::SPECTATOR_CHAINS`, `entity_outline` |
| 23 | **Horizon extras**: fullbright, dynamic lights, minimap, PvP HUD, Studio | `extras.rs`, `extras_ui.rs`, `dynamic_light.rs`, `minimap.rs`, `pvp.rs`, `pvp_hud.rs`, `studio_ui.rs` | 5,725 | **CUT** | none (all off by default) | low | `extras::Extras` fields, `graphics_ui` Quality rows, `game/extras.rs` |
| 24 | Visbuffer (experimental) | `gfx/visbuffer.rs`, `visbuffer.wgsl` | 844 | **CUT** | none (`HORIZON_VISBUFFER=0`) | low | env read at `gfx/visbuffer.rs:1` |
| 25 | Resolution scale / FXAA / TAA / upscaling | `gfx/world_post.rs`, `world_post.wgsl` | 947 | **CUT** | none (all off/native by default) | low | `graphics.{resolution_scale,fxaa,taa,upscaling}` (721-731) |
| 26 | Improved transparency (OIT) | `gfx/oit.rs`, `gfx/oit_features.rs`, 5 `oit*.wgsl` | 1,571 + 333 wgsl | **GATE** | none (`improvedTransparency` default false) | **med** — vanilla key, ~30 `!oit_on` sites | `Renderer.improved_transparency` (1569), `settings.rs:146` |
| 27 | Render capture (dev tool) | `gfx/capture.rs` | 582 | **CUT** | none | low | `Renderer::keep_capture_copies`, `horizon-ctl render-capture` |
| 28 | GPU frame timing | `gfx/timing.rs` | 376 | **CUT** | none (F3 overlay only) | low | `graphics.overlay`, `Renderer::pass_timing` |
| 29 | "RUST EDITION" banner | `title_edition.rs` | 490 | **CUT** | **yes** — but it exists *because* Mojang art isn't shipped | low | `title_edition::build`, title screen |
| 30 | Resource-pack core (packs, atlases, mipmaps, models, sprites) | `packs.rs`, `packs/`, `atlas_sources.rs`, `mipmap.rs`, `sprites.rs`, `models*`, `sprite_cache.rs`, `block_sprites.rs` | 7,992 | **CORE — do not cut** | **yes if cut** — this is how the game loads its own assets | — | — |
| 31 | Skins | `skins.rs` | 1,869 | **CORE** | none | low | keep |
| 32 | Camera / environment | `camera.rs`, `environment.rs` | 1,769 | **CORE** | none | low | keep |
| 33 | Audio | `audio.rs`, `sound_engine*`, `sound_events.rs`, `sound_preview.rs` | 5,548 | already `audio` | — | — | already gated |

---

## 2. "Vanilla look, minimum renderer"

**Definition.** A frame that is pixel-equivalent to Horizon at its defaults, which per `docs/graphics.md` are already vanilla 26.3: cave culling on, GPU/entity/particle/leaf culling off, no LOD, no upload budgets, sky/fog/weather on, 100% resolution, no AA, HDR off, no shader pack, `improvedTransparency` off.

**Kept:**
- terrain: chunk store, streaming (generate/light/mesh workers), `mesher/` + `light.rs`, section arena + resident set + upload belt, section occlusion graph, frustum culling, translucent sorting
- entities, block entities, held items, first-person hand, item/block outlines
- sky (disc, sunrise fan, stars, end sky), clouds, weather columns, all fog types
- particles
- vanilla `post_effect` chains (spectator vision, entity outline)
- HUD + all screens + settings + font + panorama + menu blur + world border
- resource packs (folder/zip, atlas, mipmap, models) — **required**, the game's own assets arrive through this path
- skins, camera, `render_tick.rs` visual ticking

**LOC:**

| Layer | LOC |
|---|---|
| GPU/world renderer (gfx core, mesher, streaming, light, chunk, sky/fog/weather, particles, block entities, post chain, item/hand) | **≈65,000** |
| + HUD, screens, font, widgets, settings UI, skins, resource-pack core | **≈84,000** |
| **Render crate after all cuts** | **≈149,200** (was 223,162) |
| Client-side graphics glue retained | **≈11,000** (was 13,773) |
| **Whole slice** | **≈160,000** (was 280,185) |

Roughly **28%** of that remaining code is tests.

---

## 3. Ranked removals

| # | Removal | LOC | Implementation notes |
|---|---|---|---|
| 1 | **OptiFine/`shaders/` shader packs** | **44,148** | Delete `gfx/pack_*.rs` (56 files), `post_glsl.rs`'s GLSL path, crate `horizon-shaders`, `game/shader_packs.rs`. In `gfx.rs`: fields `pack_post`, `pack_atlas`, `pack_material_atlases`, `pack_terrain_flat`, `pack_loading`, `pass_timing`; methods `set_shader_pack` (6897), `load_shader_pack` (7043), `poll_shader_pack` (7147), `shader_pack_loading`, `drop_shader_packs` (7178), `shader_pack_kind` (7014), `reset_shader_pack_history`, `pack_inputs` (7256), `pack_terrain_inputs` (7289), `define_pack_macros` (7409), `shader_pack_dimension` (7426), `set_pack_lava_layers`, `pack_shadow_casters`, `pack_entity_shadows`. Replace the ~150 conditional arms (`pack_reads_world`, `pack_draws_{terrain,sky,celestial,water,clouds,outline,hand,weather,shadow}`) with `false`. `Graphics::shader_pack`, `shadow_cache`, `Page::Shaders`, `options_ui::Page::ShaderPacks`. Keep `naga`'s `glsl-in`: `post_chain.rs` still needs it. |
| 2 | **OptiFine resource-pack features** | **17,023** | `connected.rs`, `cit*.rs`, `fusion.rs`, `block_entity_cem.rs`, `custom_sky.rs`, `gfx/custom_sky.rs`, crate `horizon-optifine` (both Cargo manifests). Hooks: `assets.rs:348`, `mesher.rs:1868`, `block_entity_render.rs`, `hud.rs`, `models/`, `mobs/{cem,cem_anim,random_textures,render}.rs`, `game/custom_sky.rs`. Every hook must degrade to `None`, not to a default texture, or the section-mesh parity gate breaks. |
| 3 | **LOD + BlueMap + server terrain** | **13,719** | Delete `lod.rs`, `lod/`, `gfx/lod.rs`, `terrain_model.rs`, `bluemap.rs`, `bluemap_detect.rs`, `server_terrain.rs`, `lod_net.rs`+`lod_net/`. `gfx.rs`: `clear_lods`, `lod` fields, the `far_tile`/`Part::Lod` variants and every `frame.lod*` read. `game.rs`: `prepare_lod` (14559), `clear_lod` (14542), `lod_blue_map` (2453), `update_world` call (14696). Drop `Graphics::{lod_distance,far_detail,blue_map}` and `Graphics::wide_frame()`'s far-terrain term in `camera.rs:858`. |
| 4 | **Horizon `.hshader` packs** | **13,455** | `gfx/native_*.rs` (6,023), `gfx/{displace,block_light,wgsl_prefix}.rs`, `native_emissive.rs`, `shader_ui.rs`, `shader_options.rs`, `shader_pack_list.rs`, crate `horizon-shader-api`. `Renderer::{set_native_shader_pack, native, native_shadow, pack_timing}`. `game/native_shaders.rs` (318). **Caveat:** `horizon-shader-api` is also used by `launcher/` and `horizon-mods` (`index` feature) — a launcher-bearing fork keeps the crate but drops the client half. |
| 5 | Horizon extras (fullbright, dynamic lights, minimap, PvP, Studio) | 5,725 | `extras.rs` fields, `extras_ui.rs`, `dynamic_light.rs`, `minimap.rs`, `pvp.rs`, `pvp_hud.rs`, `studio_ui.rs`, `game/{extras,tweaks,render_settings}.rs`, `game/dynamic_lights.rs`. Note `dynamic_light` is read by `terrain.wgsl`/`entity.wgsl` — set the source count to a constant 0. |
| 6 | **GPU culling** | 3,446 | `gfx/gpu_culling.rs`, `gpu_culling.wgsl`, `gpu_occlusion.wgsl`, `Renderer::gpu_*`/`GpuChecks`, `check_gpu_records`, `gpu_recorded`, `record`, `gpu_census`, `HORIZON_GPU_CULL`, `graphics.gpu_culling`. |
| 7 | **Splitscreen** | 3,626 | `split_*`, `gfx/compositor.rs`, `gfx/view.rs`; collapse `MAX_VIEWS` to 1 and delete `Frame::views` iteration. `Game.splitscreen`, `game/split/`. |
| 8 | **Frame generation** | 2,442 | `gfx/frame_gen*`; `fg_frames`, present thread split, `HORIZON_FRAMEGEN_DEBUG`, `graphics.frame_generation`. Entity motion tags live in `Frame::entity_motion`, not in the vertex format — clean. |
| 9 | **HDR** | 2,242 | `gfx/{hdr,hdr_icc,hdr_stats}.rs`, `hdr_calibration.rs`, `hdr*.wgsl`, crate `horizon-hdr`, `graphics.hdr*` (735-779), `Page::Hdr`, `Renderer::{hdr,set_hdr}`, `hdr_screenshot_path`, `hdr10_to_rgb16`. `frame_format()` collapses to the 8-bit path. **Keep** the mesher's emission bits (see §4). |
| 10 | Resource-pack browser | 2,607 | `pack_browser.rs` (Modrinth downloads), `pack_screen.rs`'s browse/paste tabs. Keep the vanilla-style pack list. |
| 11 | Improved transparency (OIT) | 1,238 | `gfx/oit.rs`, `oit_features.rs`, `oit*.wgsl`, `Renderer.improved_transparency`, ~30 `!oit_on` guards, `settings.rs:146`, `debug_keys.rs:71,744`. **Keep the key parseable** (§4). |
| 12 | Resolution scale / FXAA / TAA | 748 | `gfx/world_post.rs`, `world_post.wgsl`, `graphics.{resolution_scale,fxaa,taa,upscaling,upscaling_sharpness}`, `draw_scaled_frame`, `Renderer::world_post`. |
| 13 | Visbuffer | 417 | `gfx/visbuffer.rs`, `visbuffer.wgsl`, `HORIZON_VISBUFFER`. |
| 14 | Render capture | 582 | `gfx/capture.rs`, `Renderer::keep_capture_copies` (`gfx.rs:1576`), `HORIZON_RENDER_CAPTURE`, `horizon-ctl render-capture` / `examples/scene_replay.rs`. |
| 15 | "RUST EDITION" banner | 490 | `title_edition.rs`, `title.rs` call. |
| 16 | GPU timing | 376 | `gfx/timing.rs`, F3 overlay rows. |

**Total: ≈112,300 `.rs` LOC named in the table (37,049 of it the four crates), plus ≈3,400 `.wgsl` and ≈2,800 client glue — ≈117,300 LOC, 42% of the 280k slice.**

Breakdown of the cut: render crate 223,162 → ≈149,200 (−74,000); `horizon-client` glue −≈2,800 (`lod_net` 1,241, `game/shader_packs.rs` 1,163, `game/native_shaders.rs` 318, `game/custom_sky.rs` 75); `horizon-shaders` −21,204; `horizon-optifine` −11,299; `horizon-shader-api` −4,216; `horizon-hdr` −330; `.wgsl` 6,201 → ≈2,770.

**Cascade worth taking:** once no pack can draw flat, `PickedPack::draws_flat` is always false and `translucent_split(...)` is constant. That unlocks deleting the translucent-arena split in `gfx/arena.rs` and most of `gfx/flat.rs` (1,420). **Do not** delete `flat.rs` outright: Metal and Intel Gen11/12 Vulkan still take the flat path with no pack.

---

## 4. Where a "safe" cut silently changes vanilla

1. **HDR emission bits are baked into the mesher.** `docs/graphics.md`: "The mesher puts the light a block's face emits in its vertex colour's alpha (`EMISSION_BITS`)". `mesher.rs:254` writes them unconditionally; `terrain.wgsl:636` reads `color.a & 15`. If deleting HDR also removes the mesher's write, **the byte-for-byte section-mesh parity gate fails**. Correct cut: delete the HDR consumer passes, keep `EMISSION_BITS`, `hdr_tier`, `WHOLE` and the `scene` vertex attribute dead.
2. **`improvedTransparency` is a vanilla `options.txt` key** (also a vanilla F3 debug toggle, `debug_keys.rs:71`). Deleting OIT but dropping the key makes Horizon rewrite `options.txt` differently from vanilla, breaking the options-file parity harness. Keep writing it, keep it off.
3. **`gfx/cull.rs` is on by default.** It is conservative and pixel-identical, but deleting it costs the FPS win that pays for itself at render distance ≥16, and it changes F3's section counts. Treat as a performance regression, not a neutral delete.
4. **Resource packs are not optional.** `packs.rs`/`atlas_sources.rs`/`mipmap.rs`/`sprites.rs`/`models/` load the game's *own* assets. Cutting "resource pack support" leaves nothing to draw. Only `pack_browser`/`pack_screen` (UI) and the OptiFine extensions are removable.
5. **`mipmap.rs` implements vanilla's `scaleAlphaToCoverage`.** Without it, leaves/cactus/flowers erode into holes at distance. `ditherCutoutMips` (off) is the Horizon extra; the mipmap code is vanilla.
6. **`post_chain.rs` is vanilla, not a pack feature.** Deleting it removes spectator creeper/spider/invert vision. Its GLSL loader *is* pack-facing, so gate that half only.
7. **`gfx/entity_skin.rs` (GPU skinning) is on by default, not an option.** `EntitySkin::new` is constructed unconditionally at `gfx.rs:4599`; `Renderer::skins_entities()` returns true whenever it exists. Deleting it makes every mob take the CPU path in `mobs/render.rs` — a different vertex stream for the same silhouette. Verify mob rendering before/after, and delete `Renderer::skinned_models`, `skins_tagged`, `Frame::skin` and `entity_skin.wgsl` together rather than leaving `entity_skin == None` half-wired.
8. **`title_edition.rs` exists because Horizon cannot ship `title/edition.png`.** Deleting it does not restore "JAVA EDITION"; it leaves a blank banner.
9. **`Graphics::wide_frame()` / `camera.rs:858` mixes render distance with cloud range and LOD distance.** Removing LOD must not change the far plane or cloud range at default settings.
10. **`leaf_culling`, `cutout_leaves`, `biome_blend`, `chunk_fade`, `vignette`, `menu_blur`, `weather_radius` are all vanilla keys.** Only their *extra* modes are Horizon's. Removing the mode enum is fine; removing the key is not.

---

## 5. Appendix

**Existing cargo gates.** `horizon-client-render`: `audio` (39 sites), `test-support` (3). `horizon-client`: `default = ["audio","controllers","horizon-extras"]`; `horizon-extras = ["discord","friends","heartbeat"]`, 30 `cfg!` sites, **none of them in `gfx.rs`, `graphics*.rs`, `lod.rs`, `shader_*` or `gfx/`**. `docs/forking.md` explicitly lists "HDR, shader packs, fullbright, dynamic lights, hiding block-break particles" as *not* behind the feature.

**Runtime escape hatches** (useful for A/B during the fork): `HORIZON_VISBUFFER`, `HORIZON_GPU_CULL`, `HORIZON_FLAT_DRAWS`, `HORIZON_SHADER_PACK`, `HORIZON_SHADER_PACK_TIMING`, `HORIZON_HDR_OUTPUT`, `HORIZON_HDR_FRAME`, `HORIZON_HDR_LIGHTING`, `HORIZON_FRAMEGEN_DEBUG`, `HORIZON_STILL`, `HORIZON_SPRITE_SPLIT`.

**Test mass that goes with the cuts.** 1,753 `#[test]` fns / ~63k LOC. The pack trees alone carry ~4,900 LOC of tests in-crate plus most of `horizon-shaders`' 21k. `gfx.rs` declares five `#[cfg(test)]` submodules (`crumbling_tests`, `inter_stage_tests`, `sprite_upload_tests`, `shadow_face_tests`, `shadow_caster_tests`) plus a 1,544-line inline `mod tests`; `gfx/pack_post/` alone holds 35 `*_tests.rs` files and `gfx/pack_atlas/` 2.

**Suggested order of work** (each compiles and is independently revertible):
1. LOD + BlueMap + server terrain (self-contained, largest behavioural chunk, no shared vertex formats).
2. HDR (touches `frame_format`; do it before shader packs, which also branch on the frame).
3. Shader packs, OptiFine format first, then Horizon format (they touch the same `gfx.rs` regions; doing both together avoids editing those 150 branches twice).
4. OptiFine resource-pack features.
5. GPU culling, frame generation, visbuffer, world_post, OIT.
6. Splitscreen, extras, pack browser, capture, timing, title banner.
