# Horizon Lite — the world crate

Slice: `crates/horizon-src/crates/horizon-world` (+ `horizon-core` where it is the substrate).
Read-only analysis; no builds run. All LOC are physical lines from `wc -l` unless marked *est*.
Static-analysis caveat: "unused" below means no `horizon_world::<mod>` reference from another
crate **and** no `crate::<mod>::`/`<mod>::` use inside the crate. That is a strong signal but not a
substitute for one `cargo check` after deletion.

## 0. The shape of the crate (measured)

| Measure | Value |
|---|---|
| `.rs` files | 561 |
| total LOC | 192,797 |
| `src/` | 340 files, **147,564** LOC (11,281 of that is inline `#[cfg(test)]`, so **136,283** code) |
| `tests/` | 33 files, 4,649 LOC |
| `examples/` | 187 files, 40,856 LOC (probes/benches, not shipped) |
| `src/datafix/` | 21,365 LOC + 450 KB `block_state_data.txt` |
| `src/worldgen/` | 61,446 LOC (6,603 tests) |
| `src/level/` | 28,372 LOC (4,897 of it `tests.rs`/`growth_tests.rs`; 23,039 code) |
| `bin/` | 915 LOC (`horizon-world` CLI 198, `worldgen_parity` 717) |
| `horizon-core` | 22,459 LOC total, 2,719 of it parity bins |

The crate is deliberately **not** a game loop: `lib.rs` says "does not run gameplay". It is a
library of vanilla-exact algorithms plus data tables; the client owns the loop and implements
`level::LevelAccess`, `worldgen`'s worker traits, `loot`'s context traits, etc. That split is the
single most useful thing about the crate for a fork: almost every subsystem is already behind a
trait seam, so cutting is about *deleting + stubbing traits*, not untangling globals.

---

## 1. Subsystem table

LOC = `src/` only. "Loss" is what a player notices.

| Path / subsystem | LOC | Verdict | What is lost | Risk |
|---|---|---|---|---|
| `src/nbt.rs` | 1,265 | **CORE** | — (Tag/Compound/JavaString, named + network NBT, SNBT, 64 MiB limits) | none |
| `src/compression.rs` | 565 | **CORE** | — (gzip/zlib/none/lz4-java framing; `region-file-compression`) | none |
| `src/region.rs` | 545 | **CORE** | — (Anvil `.mca` header/sector alloc, in-place write, export) | none |
| `src/chunk.rs` | 1,238 | **CORE (subset)** | — (`BlockState`, `PalettedContainer`, `ChunkData`, `BlockSection`) | `ChunkData` is used by the CLI + one legacy migration only; the real save path is client `save.rs` |
| `src/heightmap.rs`, `chunk_status.rs`, `tick_data.rs` | 461 | **CORE** | — (6 heightmap kinds, chunk status ladder, saved-tick bridge) | `tick_data` looks unused; verify |
| `src/registry/`, `block_properties.rs`, `block_state_properties.rs` | 1,274 | **CORE** | — (block-state ID space, facts, property codecs) | 199 client refs; everything keys off `BlockStateId` |
| `src/datafix/` | 21,365 | **CUT ~91 %** | Ability to open 1.8–26.2 saves; "Optimize World" | LOW — same-version loads already bypass it (`chunk.rs:233` hard-errors; `upgrade_record` guards on DataVersion) |
| `src/worldgen/` | 61,446 | **GATE** | tier-dependent: nether/end, structures, caves, feature variety | HIGH if cut surgically; see §2/§3 |
| `src/level/` (block behaviour, ticks, redstone, placement, interaction) | 23,039 code | **CORE**, with two GATE islands | redstone/pistons are the only large optional islands | redstone: MEDIUM (≈100 call sites in 10 files). Rest: LOW |
| entity physics: `collision*`, `entity_*`, `living_*`, `movement_*`, `fluid*`, `climbing`, `swimming`, `block_landing`, `block_collision_scan`, `world_ray/movement` (35 files) | 6,322 | **CORE** | — (player/mob movement, step-up, water, fall) | LOW; `stepped_interpolation` (341) is dead here (client has its own) |
| items/inventory: `item_*`, `inventory_*`, `player_inventory`, `player_equipment`, `component_*`, `object_open_*`, `simple_container` (25 files) | 4,325 | **CORE**, some GATE | `bundle_weight` (191), `simple_container` (220) if cut | LOW |
| effects: `status_effect`, `active_effects`, `active_effect_tick`, `effect_*`, `stored_effect_attributes` | 1,816 | **CUT** | nothing — the client has its own `effects.rs` (821); these have **zero** refs outside the crate and form a closed island | LOW, but `blocking_rules`/`damage_immunity`/`damage_reduction` in the same area **are** used — keep those |
| food: `food`, `food_properties`, `food_storage`, `player_food`, `consumable` | 720 | **GATE** | hunger/saturation if cut; eating still needed for gapples | LOW (client keeps `Difficulty` from `food.rs`) |
| damage/combat: `damage_source(+resources)`, `living_damage/hurt/fall`, `player_health/hurt`, `server_player_damage/combat`, `combat_rules`, `suffocation`, `water_splash` | 2,737 | **CORE (simplify catalog)** | damage-type JSON could shrink to ~10 types | LOW |
| `src/loot.rs` | 2,439 | **CORE** | block/mob/chest drops and vanilla draw order | LOW; 213 refs in 82 client files |
| `src/attributes/` + `attribute_map` | 1,637 | **CORE** | movement speed, health, modifiers | LOW |
| `src/attachments.rs` | 695 | **GATE/CUT** | native-mod synced attachments only | MEDIUM — `horizon-protocol` imports it (1 module), client 34 refs |
| `src/environment_attributes.rs` | 658 | **CUT** | nothing — 0 refs anywhere; an unwired port | LOW |
| `src/dimension_type.rs` | 442 | **CORE** | level bounds, sea level, skybox, bed rule | LOW |
| `src/bin/*` | 915 | **CUT from default build** | dev CLI / parity harness | none |
| other (block_survival 1,220, block_placement, java_hash_map 1,050, worldgen.rs, json_*, snbt_text, identifier, lib/main) | ~8,355 | **CORE** | `block_survival` is the data-driven "torch pops off" rule set — **not** redstone | LOW |

Rows are not additive: a module appears in its functional row and, where relevant, again in the
unwired-duplicates list in §2/§5 (≈500 LOC of overlap in `items`/`attributes`).

---

## 2. The "lite world" definition

All numbers are `src/` LOC. Baseline (today) 147,564.

| Tier | Definition | LOC | Δ vs now |
|---|---|---|---|
| **T0** | today | 147,564 | — |
| **T1 — Overworld only** | 26.3 saves only (datafix gone), overworld only (no nether/end generators, features, or portals), unwired duplicates purged | **≈120,300** | −18 % |
| **T2 — T1 + no structures** | `for_world(..., structures=false)` machinery deleted (villages/temples/mineshafts/strongholds/monuments/mansions/ancient cities/ruins) | **≈97,900** | −34 % |
| **T3 — T2 + no carvers** | no caves/ravines/underground water | **≈97,100** | −34 % |
| **T4 — T3 + simplified features** | keep vanilla noise/density/climate/aquifer/surface; replace 155 feature types + placement engine with a hand-written pass; drop datapack overrides | **≈78,000** | −47 % |
| **T5 (optional) — no redstone/pistons** | buttons/levers/plates/lamps/repeaters/comparators/observers/dispensers/hoppers/rails/pistons inert | ≈75,000 | −49 % |

T1 deltas: `datafix` −19,500 · unwired duplicates −4,259 · nether/end worldgen −2,700
(fortress 935, end_city 467, fungus 300, end_spike 243, chorus_plant 204, end_podium 174,
end_gateway 121, nether_fossil 117, EndBiomeSource ~60) · portals −812.

T2 delta: structures 22,375 (`generator_structures.rs` 1,276 + `structure.rs` 419 +
`structure/**` 20,680). T3 delta: carver 794.

T4 arithmetic: −(features 11,910 + feature plumbing 4,700 + placement 2,799 +
`generator_decoration.rs` 1,687 + `overrides.rs` 546) + ~2,500 new.

**Worldgen bucket split (61,446 measured):**

| Bucket | LOC | Observable? |
|---|---|---|
| terrain core: `terrain.rs` 1,098, `density` 578, `router` 168, `climate/**` 889, `aquifer/**` 1,361, `settings`, `bulk_section`, `write_zone`, `height_provider`, `biome*`, `tags` | 7,775 | **yes** — hills, oceans, rivers, biome map |
| material rules: `material_condition/**` 2,055, `material_stage` 780, `material_surface` 142, `material_extensions` 229 | 2,855 | **yes** — grass/dirt/stone/deepslate/sand/gravel/badlands |
| `overrides.rs` (datapack layering) | 546 | no (cut for lite) |
| carvers + `carving.rs` | 794 | **yes** — caves, canyons |
| placement + state providers | 2,799 | enables features |
| feature plumbing (`feature_graph` 1,106, `feature_region` 683, `feature_catalog` 304, `decoration*`, `feature.rs`, `live.rs` 374… ) | 4,700 | enables features |
| 155 feature kinds (35 modules: trees 2,323+844, vegetation 847, ores 518, dripstone 800, sculk 727, cave/geodes 747…) | 11,910 | **yes** — trees, grass, ores, lakes, geodes |
| structures | 22,375 | **yes** — villages etc. |
| `blending.rs` (pre-1.18 seams) | 1,038 | no for new worlds |
| pipeline: `generator.rs` 5,103, `generator_decoration.rs` 1,687, `native_generate` 282, `spawn_finder` 128 | 7,200 | orchestration |

So: **terrain shape + surface = 10,630 LOC produces everything you recognise as "Minecraft
terrain"**; features add 21k; structures add 22k.

---

## 3. Exact cut points

### 3.1 datafix — CUT (21,365 → ~1,200)

Scale: **329 registered fixes over 259 distinct DataVersions**, key 100 (1.8-pre1) → 5016 (26.2);
`CURRENT = 5023`. Two thirds of it is the flattening and rename tables (`flat_tables`,
`block_state_data.txt`, `items.rs`).

**Is any of it needed for same-version loads? No.** Three independent guards:
`chunk.rs:233` rejects any `DataVersion != 5023`; `save.rs::upgrade_older_world` returns `Ok(())`
when `level.dat` is current; `save.rs::upgrade_record` returns before touching a fix.

Delete: `fixes_legacy|old|a|b|mid|cliffs|c|flat.rs` (9,793), `flat_tables.rs` (2,791),
`items.rs` (1,411), `block_state_data.rs` + `.txt` (199 + 450 KB), `chunk_flatten.rs` 771,
`chunk_leaves.rs` 488, `schema.rs` 947, `schema_flat.rs` 508, `json.rs` 709, `text.rs` 252,
`world_upgrader.rs` 673, `progress.rs` 282, `mod.rs` fix plumbing (~380), `files.rs` fix half (~1,100).

Must survive (move out of `datafix/`):
* `dynamic.rs` (264) — **an NBT accessor utility**, used 19× outside the crate (`as_int`,
  `as_str`, `namespaced`, `set`, `remove`…) by client, items and protocol. Rename to
  `nbt/dynamic.rs` or `nbt_util.rs` before deleting anything.
* `identifier()` (mod.rs) and `CURRENT`/`OLDEST_SUPPORTED` constants.
* from `files.rs`: `read_dat`, `read_saved_dat`, `write_dat`, `data_version`, `resolve`,
  `generators`, `current_world_gen_settings`, `world_dimensions` → new `src/level_dat.rs`
  (~200 LOC). **These run on current worlds** — `save.rs` calls `generators()` and
  `current_world_gen_settings()` when loading a 26.3 world.

Client-side patches: `save.rs:193 upgrade_older_world` → error "Horizon Lite opens 26.3 saves";
`save.rs:2349 upgrade_record` → delete; `title.rs:1572 fix_world_files` → delete;
`game/integrated.rs`, `game/world_loading.rs`, `game/world_session.rs` take an
`UpgradeProgress` — keep a 30-line no-op struct or delete the parameter.
Protocol: the only `datafix` uses are in the old-version adapters (`item/v1_20_3.rs`,
`adapter/translate/v1_20_3.rs`), i.e. inside the 24,197-LOC `adapter/` tree. Delete adapters →
the dependency disappears.

### 3.2 worldgen — GATE

Cheapest real switch already exists:
`OverworldGenerator::for_world(data, seed, preset, dim, with_structures, ..)` and
`OverworldGenerator::without_structures(data, seed)`; `GeneratorWorker::generate_proto`
(BIOMES→TERRAIN incl. carvers) and `::decorate` (FEATURES) are clean seams.
The client passes `structures` through `VanillaTerrain::for_world*`; passing `false` costs **0 LOC**
and removes 22k of work from the hot path.

To delete structures (T2): `worldgen/generator_structures.rs`, `worldgen/structure.rs`,
`worldgen/structure/**`; in `generator.rs` the `StructureState`, `manual_structures`, `rings`,
`saved_starts`, `possible_sets`, `by_step` fields and `Pipeline::new`'s structure branch;
`ProtoChunk::structures()/own_starts()`. Keep `structure::{BoundingBox, Rotation, Mirror}` and
`StructureTemplate` only if you keep `/place` & structure blocks (client uses
`worldgen::structure::{Mirror, Rotation}` and `save.rs` writes `structure_starts`/`references`).

To delete carvers (T3): `carver.rs`, `carver/{canyon,generation}.rs`, `carving.rs`,
`GeneratorData::biome_carvers`, `CarvingBlocks`, and the `generate_proto` mask step in
`terrain.rs`.

To simplify features (T4): delete `feature_graph.rs`, `feature_catalog.rs`, `feature_region.rs`,
`feature_sort.rs`, `decoration.rs`, `decoration_order.rs`, `generator_decoration.rs`,
`placement/**`, `state_provider/**`, `value_provider.rs`, `weighted.rs`, `block_predicate.rs`,
`rule_test.rs`, `fluid_predicate.rs`, `projected.rs`, `anchor.rs`, `live.rs`, and the 35 feature
modules; add `lite_features.rs` (est. 1,500–2,500: trees, grass/flowers, ores, lakes, sugar cane,
cactus, pumpkins). **Keep** `terrain.rs`, `density.rs`, `router.rs`, `climate/**`, `aquifer/**`,
`settings.rs`, `material_*`, `biome*`, `tags.rs`, `bulk_section.rs`, `write_zone.rs`,
`spawn_finder.rs`, and the non-feature half of `generator.rs`.
Then `GeneratorData::load`'s 19-bundle list can drop `features`, `placed_features`,
`feature_tags`, `state_providers`, `template_pools`, `processor_lists`, `structures`,
`structure_sets`, `biome_tags`, `world_presets` — faster start, less RAM.

Contract that must not change: `ProtoChunk`/`TerrainChunk` (`terrain.rs`) and
`GeneratorWorker::{generate_proto, decorate}`. `crates/horizon-client/src/vanillagen.rs`
(1,130) implements `ChunkGenerator` (`client-render/src/streaming.rs:70`) over them and converts
`ProtoChunk → Chunk`; the streaming worker pool calls it.

### 3.3 level — CORE, with two severable islands

* **Redstone** (`redstone.rs` 1,541 + `redstone/experimental.rs` 214 + `signals.rs` 45 = 1,800):
  severable but pervasive. 101 helpers are called from `hooks.rs` (40 refs),
  `interact.rs` (13), `place.rs` (12), `tick.rs` (11), `mod.rs` (10), `pistons.rs` (4),
  `shapes.rs` (3), `rails.rs` (3), `update.rs`, `sculk.rs`, `shelf.rs`. Stub
  `Sim::has_neighbor_signal`/`best_neighbor_signal`/`signal` to `0`, delete the redstone arms of
  the `Class::` matches, and the `Ticks::{comparator_outputs, torch_toggles}` state.
  **Block placement does not depend on redstone**: `block_survival.rs` has zero redstone
  references (its rules are data tables from `survival-rules.json`), so torches still pop off
  walls. `place.rs`'s seven uses only initialise *powered* state (skull, shelf, crafter, fence
  gate, lamp, wire, door) — with the stub returning 0 everything places unpowered, which is the
  correct look for a world with no power. Loss: doors by hand, no lamps/repeaters/observers/
  dispensers/hoppers/note blocks/daylight detectors/sculk sensors.
* **Pistons** (`level/pistons.rs` 954 + `piston_push.rs` 483 + `piston_shape.rs` 197 +
  `piston_movement.rs` 50 + `block_entity_push.rs` 75 = 1,759): depends on redstone signals and
  moving-block entities; delete both or neither.

Keep: `tick.rs` (scheduled + random ticks: crop growth, fire, ice, leaf decay), `place.rs`,
`interact.rs`, `shapes.rs`, `update.rs` (neighbour/shape updates), `fluids.rs`, `growth.rs` +
`bonemeal.rs`, `data.rs` (the prepared tables), `weather.rs`, `rails.rs` only if redstone stays.
`LevelAccess` (~40 methods) is the client-facing contract and stays whatever is cut.

### 3.4 Serialization minimum (.mca + level.dat)

`nbt.rs` + `compression.rs` + `region.rs` + `chunk.rs` (`BlockState`, `PalettedContainer`,
`ChunkData`, `BlockSection`) + `heightmap.rs` + `chunk_status.rs` + `registry/` = **5,344 LOC**.
`level.dat` *encoding* is client-side (`save.rs`, 8,884 LOC); the world crate only supplies NBT
and the `level_dat` helpers above. Note `region.rs` writes vanilla-compatible headers, sector
allocation and all four codecs; `RegionFile::export`/`RegionWriter` are offline-tool only.

---

## 4. Warning list — looks optional, is load-bearing

1. **Single player is a network client of an in-process server.** `game/integrated.rs` runs a
   second `Game` on a "Server thread"; the window joins over memory. So `horizon-protocol` is in
   the single-player dependency graph, chunk streaming is packet streaming, and entity sync is
   needed even in SP. Do not plan "cut networking" without rewriting `integrated.rs` (1,409) +
   `lan/*` + `remote_*`. (The *world crate's* `stepped_interpolation` is a duplicate of the
   client's own tracker, so that copy really is dead; the feature is not.)
2. **`horizon-protocol` needs `horizon-world::nbt`** (73 refs), plus `snbt_text`, `identifier`
   (item names) and — in the old-version adapters only — `heightmap`/`datafix`.
   `nbt.rs` is the true shared layer; it is also the only thing `horizon-command` (14 refs) and
   `horizon-client-core` (28) take. The 26.3 chunk codec has its own heightmap type.
3. **`datafix::dynamic` is not a datafixer.** Delete the module wholesale and 19 external call
   sites break in client, items and protocol.
4. **`datafix::files` is also `level.dat` plumbing.** `generators()` and
   `current_world_gen_settings()` run on every current-world load.
5. **Worldgen features are runtime gameplay, not just decoration.** `level/growth.rs` uses
   `worldgen::live::LiveFeatures::place_placed` for saplings/huge mushrooms, and
   `bonemeal.rs` uses it for bone meal; the client installs it in `game/growth.rs` and
   `world_loading.rs`. Kill the feature graph and trees stop growing from saplings unless
   `lite_features` implements growth too.
6. **`client-render` stores `worldgen::structure::StructureStart` inside `Chunk`**
   (`chunk.rs:592`, 9 refs) and `save.rs` serialises `structure_starts`, `references` and
   `jigsaw` state. Cutting structures needs those fields emptied or removed, not just the
   generator flag.
7. **`registry.rs` is the ID space** (199 client refs, plus items/render). `BlockStateId` is the
   wire/palette/save currency; never cut it.
8. **`chunk.rs` is not the save path.** The live save encoder is `client/src/save.rs`; cutting
   `chunk.rs` to save lines breaks `save/gateway.rs`, the CLI and the palette reader, but not
   saving. Conversely, keeping `chunk.rs` does not give you a save format.
9. **`level/` needs prepared resources** from the player's own jar:
   `block-behaviours.json`, `gameplay-facts.json`, `block-tags.json`, `cached-collision.nbt`,
   `survival-rules.json`, `placement-definitions.json`, `facts.json`, plus `worldgen/*.json`
   (19 bundles) and `structure/**/*.nbt`. They are produced by `horizon-prepare` and cannot be
   committed (`.local/`, `tools/check_public_tree.py`). Horizon Lite still needs `horizon-prepare`
   and a Minecraft install; a "no-strings" lite build would need a hand-written block table
   (est. 5–10k) — much worse than the 1.8k redstone island.
10. **Effects are safe to cut; `blocking_rules` is not.** `status_effect`, `active_effects`,
    `effect_*`, `stored_effect_attributes` are a closed island (0 refs in any other crate), but
    `blocking_rules` (95) is used by client `health.rs`/`motion.rs`, and `damage_immunity`/
    `damage_reduction` are used by the damage code. Check module by module.
11. **`blending.rs` is pre-1.18 only** — but vanilla 26.3 writes `blending_data` into chunks
    generated next to old terrain. Cutting it is safe only if you also refuse to generate next to
    such chunks (or accept the seam).
12. **Nether/End removal is small code, large behavioural surface**: portals (`level/portal.rs`
    + `portal_travel.rs` 812), `dimension_type`'s Nether/End variants, `Skybox::End`,
    `CardinalLight::Nether`, `biome_source`'s `checkerboard`/`the_end`, `multi_noise`'s
    `"nether"` branch, and every `Class::EndPortalFrame` / `RespawnAnchor` arm in `redstone.rs`
    (which dies with redstone anyway).
13. **`horizon-world`'s `bin/worldgen_parity.rs` and the 40.8k `examples/`** are dev surface.
    Exclude from the shipped build (`default-run`/`autobins = false`) rather than deleting: the
    parity probes are the spec for anything you keep.

---

## 5. Suggested order of work (lowest risk per LOC removed)

1. `datafix` −19.5k (mechanical, guarded by an explicit "26.3 only" error). Do this first.
2. Purge unwired duplicates −4.3k (effects island, `environment_attributes`,
   `stepped_interpolation`, `inventory_use`, `simple_container`, `registry_collision_scan`,
   `registry_fall_ray`, `attribute_updates/health`, `live_attribute_updates`).
3. Ship `structures=false` as a config (0 LOC, immediate speed win) before deleting the code.
4. Nether/End −2.7k + portals −0.8k.
5. Only then decide T3/T4 on worldgen, and only with a screenshot diff harness: T4 is the only
   cut that changes the *look* of the overworld.
