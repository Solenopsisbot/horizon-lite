# World tick / TPS and chunk pipeline audit

Read-only static audit of `/home/solenopsisbot/coding/mc/horizon-lite` at current HEAD,
2026-11-08. No cargo builds or profiling runs were made; every "cost" below is an
operation-count estimate, and each one names the span to measure it with.

Two structural facts frame everything:

- Single player is **not** in-frame. The window is a client of an integrated server
  thread (`game/integrated.rs::run_integrated`, `lan_host` + `Lan::connect_local`).
  Everything in `tick_world` runs on the **server thread**; the window runs
  `tick_remote` (`game/remote.rs:6505`). TPS is therefore the integrated server's tick.
- The tick rate is 20/s by default (`clock.rs:130`, `Timer::new(20.0, …)`), and
  `FixedStep::advance` (`clock.rs:393`) lets a frame catch up at most 10 ticks.
  `/tick rate` can raise the rate, but only headroom from the work below makes that useful.

## 1. Tick order and per-tick subsystems

### 1.1 `Game::tick` preamble — `game.rs:7564`

| # | Call | Line | Scope | Cost shape |
|---|------|-----:|-------|------------|
| 1 | `tick_debug_keys` / `tick_debug_charts` | 7572–7573 | per tick | O(1) |
| 2 | `tick_tutorial` | 7574 | per tick | O(1) |
| 3 | `refresh_creative_tabs` (Creative screen only) | 7576 | per tick | O(items) |
| 4 | `tick_remote()` early return for a client | 7586–7587 | per tick | — |
| 5 | `repro_tick`, `track_experience_display`, `tick_enchanting_book` | 7592–7594 | per tick | O(1) |
| 6 | weather timers/levels | 7607–7615 | per tick | O(1) |
| 7 | `tick_weather_effects` | 7618 | per tick | O(1) |
| 8 | `finish_player_autosaves(false)` | 7619 | per pending player | amortised |
| 9 | autosave countdown / `save_game_with` | 7622–7633 | every 6000 ticks | **spike**: encodes changed chunks |
| 10 | `advance_clock`, `load_scoreboard`, `tick_functions` | 7635–7645 | per tick | scoreboard: 2-field check; functions: empty schedule is cheap; a real `minecraft:tick` function is not |
| 11 | `tick_totem`, `tick_command_extras`, `native_tick` | 7653–7657 | per tick | O(1) with no mods |
| 12 | `tick_world(running)` | 7658 | per tick | below |

### 1.2 `Game::tick_world` — `game.rs:7662`

| # | Call | Line | Scope | Cost shape |
|---|------|-----:|-------|------------|
| 1 | `native_joins_flush` | 7664 | per pending join | O(pending) |
| 2 | `share_spawn_conditions` | 7665 | per tick | O(1) |
| 3 | `update_chunk_tickets` | 7667 | per tick | O(players + forced); rebuilds the ticket grid only when `Sources` changes (`ticket_levels.rs:251`) |
| 4 | `score_destroyed_entities` | 7668 | per tick | O(1) |
| 5 | `tick_effects(running)` | 7669 | per player / mob effects | server with no local player: early-out; guest effects tick in `tick_guests` |
| 6 | `tick_hud`, `tick_bundle_hover` | 7676–7677 | per tick | O(1) |
| 7 | `tick_local_hand` | 7684 | per player | O(1) |
| 8 | `postprocess_chunks` | 7685 | **per chunk with postprocess marks** | scans every resident chunk (`postprocess.rs:16–26`), then applies fluid/shape updates for ready ones; world-load cascade |
| 9 | `tick_lan_packets` | 7688 | per packet | O(packets) |
| 10 | **`tick_blocks`** | 7689 | per level | §1.3 |
| 11 | `begin_ordered_ticks` | 7695 | per tick | O(kind lists), 8 min-scans |
| 12 | paintings / item frames / knots / armor stands / cushions | 7697–7702 | per entity of kind | O(n) |
| 13 | portal arrivals, vehicle portals, boats, carts, vehicle watch | 7706–7712 | per entity of kind | O(n) |
| 14 | thunder, lecterns, maps, lodestones, bolts, fishing, tridents, rockets, ominous spawners | 7714–7727 | per entity/block of kind | O(n); empty lists are cheap |
| 15 | entity portals / end gateways | 7730–7733 | per entity | O(n) |
| 16 | `tick_items` | 7735 | **per dropped item** | O(n) with spatial grids; `tick_dropped_items` (4455) is a full pass |
| 17 | `hoppers_catch_items` | 7737 | **per dropped item** | block lookups under every moving item (`machines.rs:843`) |
| 18 | leaves flush, `touch_arrows` | 7740–7742 | per pending/arrow | O(n) |
| 19 | `spawn_loaded_entities` | 7744 | per loaded chunk | O(n) |
| 20 | **`tick_mobs`** | 7749 | per mob | §1.4 |
| 21 | `recheck_golem_openers` | 7752 | per tick | O(villagers) |
| 22 | `run_ordered_ticks` (orbs/TNT/falling) | 7755 | per orb/TNT/falling block | O(n log n)-ish, sorted once |
| 23 | `tick_experience` | 7756 | per orb | O(n) |
| 24 | entity portals again | 7759–7762 | per entity | O(n) |
| 25 | `tick_lan(false)` | 7776 | per entity, when guests exist | §1.5 |
| 26 | `tick_hand`, `tick_sleep`, sleep status, beds | 7782–7785 | per tick | O(1) |
| 27 | `tick_end` | 7787 | per tick | O(1) outside the End; dragon fight inside |
| 28 | late ordered ticks, wind pushes | 7796–7797 | per entity | O(n) |
| 29 | **`tick_moving_pistons`** | 7804 | per moving piston BE | O(pistons) |
| 30 | **`tick_block_entities`** | 7805 | **per ticking block entity** | O(tickers), each cheap unless hopper/furnace/crafter active (`block_entity_ticks.rs:44`) |
| 31 | `tick_sculk_entities` | 7806 | **per mob + per dropped item** | full passes even with zero sculk blocks (`sculk.rs:1106`, `1763`) |
| 32 | `tick_sculk_blocks` | 7807 | per sculk BE | index scan `sculk.rs:951` |
| 33 | `tick_block_entity_anims` | 7812 | per animated BE | server: conduit/bell/gateway lists |
| 34 | `settle_hurt_teleports`, `tick_particles`, `tick_client_ambient` | 7816–7818 | per tick | server: ambient early-outs; particle context build is small |
| 35 | `tick_frame_visuals` | 7820 | per tick | O(1) |
| 36 | `tick_game_tests` | 7823 | per tick | **early-out when no runner** (`game_tests.rs:718–722`) |
| 37 | `publish_boss_bars` | 7826 | per tick | O(bars) |
| 38 | `lan_note_joined` | 7840 | per tick | O(1) |

### 1.3 `Game::tick_blocks` — `game.rs:5157`

| # | Call | Line | Scope | Cost shape |
|---|------|-----:|-------|------------|
| 1 | `tickets.tick_portal` | 5160 | per portal ticket | O(portal tickets) |
| 2 | `sync_tick_chunks` | 5161 | per membership delta | O(deltas) |
| 3 | `start_ticking_chunks` | 5162 | per chunk with saved ticks | O(waiting) (`tick_chunk_membership.rs:116`) |
| 4 | build `ticking: Vec<ChunkPos>` | 5168–5181 | **per resident chunk** | `levels.random_ticking` + `ticking_chunk` = **9 hash lookups per chunk**, 625 chunks at sim 12 |
| 5 | entity-inside boxes | 5187–5360 | **per player/cart/guest/arrow/trident/mob** | `touch(bounds)` expands every entity AABB into block positions, then `senses_entities` fact lookup per position (`5285–5357`) |
| 6 | `process_level_events` | 5362 | per level event | O(events) |
| 7 | `tick_scheduled` | 5368 | per due block/fluid tick | queues capped at 65536 each (`tick.rs:1787`, `1812`) |
| 8 | random ticks | 5370–5403 | **per random-ticking chunk × ticking section × speed** | `tick_chunk_random_masked` (`tick.rs:1871`); mask cache in `random_tick_sections.rs:102` |
| 9 | `lan_broadcast_changes` | 5405 | per changed block | O(block log) |
| 10 | `run_block_events` | 5407 | per block event | O(events) |
| 11 | `process_level_events` | 5411 | per level event | O(events) |
| 12 | `sync_moving_pistons` | 5413 | per piston | O(pistons) |

### 1.4 `Game::tick_mobs` — `game.rs:10792` → `tick_creatures` (`creatures.rs:1059`)

| # | Call | Line | Scope | Cost shape |
|---|------|-----:|-------|------------|
| 1 | `sync_mob_death_protection`, leads, gear | 10793–10798 | per mob | O(n) |
| 2 | **`spawn_natural`** | `creatures.rs:1068` | **per player × 289 spawn chunks** | O(mobs) `Counted` vec, `SpawnState`, shuffle, 3 packs × 4 attempts per chunk (`natural_spawning.rs:753`) |
| 3 | wandering trader / patrol / cat spawner / village siege | 1071–1074 | per tick each | patrol rebuilds `village_centers()` (O(villagers)) every tick (`raids.rs:1291`) |
| 4 | **`tick_raids`** | 1076 | per tick | `register_loaded_raiders` + `raider_infos` + `sync_raiders` scan **all mobs** even with zero raids (`raids.rs:569`, `541`, `831`) |
| 5 | **`tick_creature_entities`** | 1079 / `creatures.rs:1091` | **per mob** | snapshot build (`1127`), `SeenGrid` build (`1183`), AI tick (`1320`), second target pass (`1436`) |
| 6 | stats, scoreboard, bossbars, border, subtitles, phantoms, advancements, player model, emotes | 10800–10808 | mostly O(1)/player | phantoms gated by a 60–120 s countdown (`stats.rs:420`) |

AI itself: `mobs::riders::tick` → `Mob::tick` (`mobs.rs:4032`) → `ai::tick` (`mobs/ai.rs:614`)
→ `server_ai_step` (`ai.rs:1943`). Pathfinding is `nav.rs` (`nav_tick` ~508,
`recompute_path` 435, at most every 20 ticks), A* in `path.rs` with
`max_visited_nodes = 256` default (`nav.rs:93`, updated at 209). Brains:
`animal_brain.rs` 3057, `monster_brain.rs` 1595, `villager_brain.rs` 4611.

### 1.5 `tick_lan` entity tracking — `game/lan.rs:2592`

With a guest present (single player always has its owner over the memory pipe),
`lan_entities` (`lan.rs:1920`) builds a full `States` snapshot **per mob, item, orb
and object every tick**, including metadata, equipment and attributes
(`1937–2040`). It reuses buffers (`lan/entity.rs:145`) but is still a full entity pass.
`tick_lan` also clears `needs_sync` over `mobs`, `projectiles` and `dropped`
(`2689–2699`) — three more full passes.

## 2. What dominates

No numbers were measured. Ranked by operation count and the code's own
structure, for a typical single-player overworld at sim 12 with ~150–200 mobs:

| Rank | Subsystem | Est. share of tick | Why |
|---:|---|---:|---|
| 1 | Mob AI + entity tick (`tick_creature_entities`) | **35–55%** | per-mob full AI, goals, brain, A* every 20 ticks, snapshot/`SeenGrid` rebuild |
| 2 | Natural spawning (`spawn_natural`) | **15–30%** | 289 chunks × categories × 3 attempts × 4 pack, structure refs and biome spawn lists per attempt, plus an O(mobs) `Counted` vec every tick |
| 3 | Random ticks | **8–20%** | 3 draws × every randomly ticking section × every simulated chunk; 625 chunks even when nothing ticks |
| 4 | Entity-inside + item/block-entity ticks | **5–12%** | O(entities × AABB cells) block lookups; per-item hopper checks; per-ticker block entity pass |
| 5 | O(mobs) bookkeeping (raids, patrol, sculk, LAN snapshot) | **5–15%** | 5–7 full passes over the mob list per tick, several with allocations |
| 6 | Scheduled ticks / redstone / pistons / fluids | 0–10% | proportional to actual scheduled content; idle ≈ 0 |
| 7 | Functions / command blocks / game tests / advancements / scoreboard | **<1% each** | early-outs and small trigger lists when unused |
| 8 | Persistence | 0 per tick, spike every 6000 ticks | autosave encodes changed chunks |

Chunk generation, lighting and meshing are **not on the tick thread**; they run on the
shared worker pool (`horizon_threads::jobs`) and affect TPS only by competing for cores
and memory bandwidth (the server thread is prioritised via `favour_current`/
`behind_server`, `horizon-threads/src/lib.rs:89`, `:179`).

**Measure before cutting.** `HORIZON_SPIKES=2` prints every server tick slower than
2 ms with its spans (`spans.rs:1–6`): look for `tick`, `tick_blocks`, `tb_tickets`,
`tb_chunks`, `tb_entity_inside`, `random_ticks`, `tb_broadcast`, `tb_block_events`,
`tb_pistons`, `tick_mobs`, `spawn_natural`, `sn_candidates`, `sn_state`,
`tick_creature_entities`, `creature_prepare`, `lan_entity_states`, `tick_game_tests`.
On a dedicated server `horizon-report 60` also writes per-mob sampled cost
(`game/dedicated/report.rs`, `tick_profile.rs`).

## 3. Feature-removal candidates

LOC are current file sizes. "TPS" means the game-thread tick; "worldgen" means
worker-side chunk generation/decoration only.

| Candidate | LOC | Call sites | Visible change | Risk | Helps |
|---|---:|---|---|---|---|
| **Natural spawning** | 1185 client (`natural_spawning.rs`) + 1530 `mobs/spawn_selection.rs` + 752 `spawn_rules.rs` | `creatures.rs:1068` every tick; `spawn_fresh_chunks` 1055 for gen packs | no new natural mobs; world slowly empties as mobs despawn (spawner blocks/trial spawners still work) | LOW–MED | **TPS, big** |
| **Mob AI / brains** | `mobs/` **106,539** (107 files): ai 5858, goals 3514, animal_brain 3057, monster_brain 1595, villager_brain 4611, path 1570, nav 868 | `creatures.rs:1320` → `mobs::riders::tick` → `ai::tick:614` | mobs stand/slide, no targeting, fleeing, pathing, breeding, villager work | HIGH (base_tick burns/despawn entangled) | **TPS, largest** |
| **Villagers + raids** | villagers 592, villager_brain 4611, trading 941, raids 1669, wandering 249, cat 138, zombie_villagers 384, golems 396 | `tick_raids` 1076, `tick_wandering_trader` 1071, `tick_cat_spawner` 1073, siege/patrol 1072/1074 | no villagers, trades, raids, iron golems, traders | MED | TPS (only when those entities exist; idle scans are the baseline win) |
| **Sculk** | 2722 client (`sculk.rs`) | `tick_sculk_entities` 7806, `tick_sculk_blocks` 7807 | no sensors, shriekers, catalysts, wardens, vibration particles | HIGH (85 `self.sculk` sites) | TPS **only** the O(mobs/items) idle scans — a 2-line early-out gets the same |
| **Random ticks** | `tick.rs` 1988 (shared with scheduled ticks) + `random_tick_sections.rs` 634 | `game.rs:5371` | crops/trees/ice/fire/copper stop growing; fluids still scheduled | LOW (gamerule 0) | TPS proportional to ticking sections |
| **Redstone** | `redstone.rs` 1541 + `redstone/experimental.rs` 214; `update.rs` 702 is shared | neighbour updates, scheduled ticks, comparator output map (`game.rs:5062`, `ticks.rs:26`) | wires/repeaters/pistons/observers/lamps stop; buttons/doors still work | MED (update path shared) | only machine-heavy worlds; idle ≈ 0 |
| **Functions + command blocks** | functions 1913, command_blocks 1103, commands dir 16,245 | `tick_functions` 7645; command block level events | no datapack functions, command blocks, `/commands` | MED | **≈0 at idle** — not worth it for TPS |
| **Game tests** | 1650 + `test_*` modules | `tick_game_tests` 7823 | no `/test` | LOW | **0** (early-out `game_tests.rs:720`) |
| **Advancements / stats / scoreboard** | 3118 / 639 / 1201 | 10806 / 10800 / 10801 | no advancements, stats, sidebar | MED (persist reads teams) | small (`check_inventory_trigger` hashes 41 slots); not worth alone |
| **Structures** | `worldgen/structure/` **20,680** of 59,215 worldgen | `world_loading.rs:716` `automatic_structures`; start cache `generator_structures.rs`; `decorate` `generator_decoration.rs:388` | no villages, temples, fortresses, mineshafts, outposts | LOW–MED | **worldgen only**, big |
| **Carvers** | 498 + `carving.rs`/`cave.rs` | `carver/generation.rs:125` | no caves/canyons/ravines — huge terrain change | MED | worldgen only, big |
| **Features / decoration** | feature_graph 1106, vegetation 847, tree 844, ore 518 | `generator_decoration.rs:388` | no trees, ores, grass, flowers, mushrooms | HIGH (looks like a different game) | worldgen only, big |

Feature cuts that are **not** worth doing for speed: functions, command blocks, game
tests, advancements/stats/scoreboard. They cost almost nothing when the content is
absent, and they are broad edits (22k/6.5k call-site-heavy LOC per the repo's own
`docs/lite/reports/game.md` table). Redstone is event-driven; deleting it buys nothing
on a world with no machines.

## 4. Defaults that matter

| Setting | Default | Where | Effect |
|---|---:|---|---|
| `render_distance` | 12 | `horizon-client-render/src/settings.rs:222` | loaded columns; also integrated view distance (`integrated.rs:796`) |
| `simulation_distance` | 12 | `settings.rs:223`; clamp `max(2)` `game.rs:5130`, `integrated.rs:805`; dedicated 2–32 `dedicated.rs:1062` | **entity-ticking, random-tick and block-tick radius** |
| `entity_distance` | 1.0 | `settings.rs:240` | client tracking range only (not server AI) |
| `random_tick_speed` | 3 | `horizon-client-core/src/gamerules.rs:108`; save defaults `save.rs:3375`; world default `level/mod.rs:228` | random ticks per ticking section per chunk |
| spawn caps | monster 70, creature 10, ambient 15, water 5/5/5, water ambient 20 per 289 chunks | `mobs/spawn_selection.rs:106–122` | global mob population |
| `spawn_mobs`, `spawn_monsters`, `raids`, `spawn_patrols`, `spawn_phantoms`, `spawn_wandering_traders` | all true | `gamerules.rs:110–130` | natural spawning and the custom spawners |
| `spectators_generate_chunks` | true | `gamerules.rs` | spectator chunk tickets |
| `chunk_updates` / `upload_budget_kib` | 0 / 0 (unlimited) | `graphics.rs:802–804` | uploads per frame; 0 uses the 2 ms/6 ms auto budget |
| worker threads | 0 = cores−1 | `graphics.rs:1090`, preset values `graphics.rs:1122` | chunk pool size |
| LOD distance | 0 (off) | `graphics.rs:785` | far terrain threads |

**Simulation distance is the cleanest TPS scaler.** Entity-ticking chunks =
`(2·sim+1)²`: 12 → **625**, 8 → **289 (−54%)**, 6 → **169 (−73%)**, 4 → **81 (−87%)**.
Random ticks use the same radius (`ticket_levels.rs:210`), and natural spawn candidates
are filtered to ticking chunks (`natural_spawning.rs:745`).

A "speed" default that keeps the game recognisable:
`render 10, simulation 8, entity distance 0.75, particles 2 (minimal), random_tick_speed 1`.
A "max TPS" default: `render 8, simulation 6, entity 0.5, particles 2, random_tick_speed 0,
spawn_mobs false, spawn_monsters false, raids false, spawn_patrols false,
spawn_phantoms false, spawn_wandering_traders false, spectators_generate_chunks false`.
Edits: `settings.rs:218–245`, `gamerules.rs:60–130`/`save.rs:3375`, and optionally
`apply_preset` (`graphics.rs:1122`) so the Performance preset is the shipped default.

## 5. Chunk pipeline: knobs and current values

One shared pool (`horizon_threads::jobs`), threads = `cores − 1`
(`jobs.rs:172–196`, `graphics.rs:1090`; override `HORIZON_JOB_THREADS`).

| Stage | Current bound | Line |
|---|---|---|
| generation in flight | `workers * 3` | `streaming.rs:2123` |
| decoration in flight | `< workers * 2` | `streaming.rs:1848`, `1892` |
| lighting in flight | `workers * 4` | `streaming.rs:1976` |
| meshing in flight | `workers * 32` | `streaming.rs:2067` |
| area sweep | every 8 updates, plus on view move | `streaming.rs:1633` |
| inline relight vs worker relight | 4096 edits | `streaming.rs:3112` |
| light chunk queue cap | 65,536 | `light.rs:307` |
| section upload staging | 4 MiB; compact budget 32 MiB | `gfx.rs:868`, `876` |
| per-frame uploads | 2 ms (6 ms while arriving), ≤8 unqueued | `game.rs:591–597`, `14855–14923` |
| light region | full 3×3 `Arc<Chunk>` per column | `streaming.rs:1441` |
| mesh region | 3×3 `Arc<Chunk>` per column, one job per section | `streaming.rs:1490`, `2069–2101` |

Two pipeline-specific costs stand out:

- **Frontier re-generation.** At the edge of an existing world, decorating a new chunk
  next to already-final chunks calls `proto_beside_final` once per final neighbour —
  a **full terrain re-generation of that column** (`vanillagen.rs:808`, called from
  `streaming.rs:941–945`) — then `final_writes` compares every block of the column
  (`16×16×384 ≈ 98k` reads) to collect differences (`vanillagen.rs:821–841`). It is
  repeated per decoration job, so the same final neighbour is re-generated many times.
- **Carvers.** Every chunk queries 289 origin chunks and their biome carver lists
  (`worldgen/carver/generation.rs:125–157`). This is per-chunk worldgen, not tick.

Tuning that actually changes behaviour (not just reordering):

1. Light is on the critical path for meshing; raise `workers * 4` → `workers * 6` and
   lower meshing `workers * 32` → `workers * 8` so stale far meshes stop crowding out
   new near ones. Raise generation `3` → `4` only if workers idle waiting on generation.
2. Cache `proto_beside_final` by final-chunk position + membership revision (or skip it
   when the final chunk has no structure refs and was saved). This is the biggest
   chunk-load win when exploring an old world, invisible if you always generate fresh land.
3. Budget `dirty_sections`/`dirty_light` work per frame (the lists are iterated in full
   every frame: `streaming.rs:1964–1992`, `2029–2059`); a teleport or `/fill` otherwise
   produces a multi-thousand-column frame.
4. `scan_age >= 8` → 20 for the full-chunk sweep (`streaming.rs:1633`); keep the
   on-view-move sweep.
5. For fewer hitches, set explicit `chunk_updates = 12`, `upload_budget_kib = 4096`
   (`graphics.rs:802`) or lower `AUTO_UPLOAD_TIME_ARRIVING` 6 → 3 ms (`game.rs:595`).
   This trades load speed for stable frames.
6. On a 4–8 core machine, set workers to `cores − 2` if the server thread spikes while
   chunks stream; the default `cores − 1` + server + render oversubscribes by one.

## 6. Top 10 changes, ranked

Impact is estimated headroom; measure with `HORIZON_SPIKES` before/after.

| # | Change | Exact edit points | Expected impact | Risk |
|---:|---|---|---|---|
| 1 | **Ship the Performance preset as default** (render 8, sim 6, entity 0.5, particles 2) | `settings.rs:218–245`; `graphics.rs:1121–1145` if presets drive defaults | **TPS +25–45%** in mob-heavy worlds (entity-ticking chunks 625→169), frame +10–25% | LOW (user-visible distance) |
| 2 | **Skip idle O(mobs) scans**: return from `tick_raids` when no raids/raiders; build `village_centers()` only when the patrol/siege is due; return from sculk entity/block phases when `sculk.index` is empty | `raids.rs:603` (after `load_raids`), `raids.rs:1256` (after `next_spawn_time`/timer gate), `sculk.rs:913` and `930` (before `sculk_prepare`/`sculk_step_on`/`tick_entity_events`) | **+0.1–0.5 ms/tick** at 200 mobs, zero visual change | LOW |
| 3 | **Natural spawning**: skip the pass when `spawn_mobs=false`, when no category is under its cap, and reuse the `Counted` vec instead of rebuilding it every tick | `natural_spawning.rs:753–853` (early-outs after `spawning_chunks`; cache `counted` by mob-list revision) | **+0.5–3 ms/tick**; no new mobs if disabled | LOW–MED |
| 4 | **Cache "ticking chunk"**: maintain the set beside `TickChunkMembership` instead of 9 hash lookups × ~900 calls/tick | `game.rs:5168–5181` (use set), `5144`, `natural_spawning.rs:745–747`, `ticking_chunk` `game.rs:2332` | **+0.2–0.6 ms/tick** | LOW |
| 5 | **Random ticks**: default speed 3 → 1, and/or only tick chunks within N of a player | `gamerules.rs:108`, `save.rs:3375`; radius filter at `game.rs:5168` or `tick.rs:1878` | **+0.3–2 ms/tick**; crops 3× slower | LOW |
| 6 | **Mob AI distance gate**: mobs beyond 48–64 blocks of every player get despawn/age only, not goals/brain/path | `creatures.rs:1239–1258` (branch after `ticking`), `mobs/ai.rs:614` (skip `server_ai_step`) | **+1–4 ms/tick** in mob-heavy worlds; invisible at distance | MED |
| 7 | **Chunk pipeline retune**: light 4×→6×, mesh 32×→8×, gen 3×→4× | `streaming.rs:1976`, `2067`, `2123` | **−10–25% chunk-load time**, fewer stale meshes/frame | LOW |
| 8 | **Cache frontier protos** (`proto_beside_final`) instead of re-generating each final neighbour per decoration job | `vanillagen.rs:808`, `streaming.rs:941–945`; cache keyed by `(x,z)` + `world.chunks.membership_revision()` | **−10–40% load time** when crossing an old frontier | MED |
| 9 | **Worldgen off switch**: default `structures=false` for a fast world; optional empty carvers / fewer features | `world_loading.rs:716`; worldgen bundle carver lists; `WorldGen.structures` default | **−30–60% chunk-gen CPU** (load only, not TPS); loses structures/caves | LOW–MED (content) |
| 10 | **Frame budget for streaming**: cap dirty sections/light per frame, sweep 8→20, explicit upload budget 12/4096 | `streaming.rs:1633`, `1964–1992`, `2029–2059`; `game.rs:591–597`, `14886–14922` | **fewer 30–80 ms frames** on flight/teleport; small TPS gain | LOW |

Not worth doing for TPS: game tests (early-out), functions/command blocks (empty
schedule), advancements/scoreboard (small per-tick work), and redstone on a world
without machines (event-driven). The large architectural lever — deleting the LAN hub
snapshot path and ticking single player in-frame — is the repo's own 250–400 h
"Option B" (`docs/lite/reports/game.md:304–309`), not a quick win.

## Verification recipe

```sh
# Per-tick spans (name, wall ms, CPU ms) for ticks > 2 ms:
HORIZON_SPIKES=2 ./horizon-client

# On a dedicated/integrated server console, per-mob sampled cost + worker job times:
horizon-report 60

# Job pool size:
HORIZON_JOB_THREADS=8 ./horizon-client
```

Read `tick_blocks`'s laps first (`tb_tickets`, `tb_chunks`, `tb_entity_inside`,
`random_ticks`, `tb_broadcast`, `tb_block_events`, `tb_pistons`), then `spawn_natural`
(`sn_candidates` … `sn_finalize`), then `tick_creature_entities`/`creature_prepare`,
then `lan_entity_states`. If `tick` ≫ the sum of those, the remainder is the many
per-kind entity passes in §1.2.
