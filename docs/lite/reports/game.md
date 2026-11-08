# Horizon Lite — gameplay slice audit (`horizon-client/src/game.rs` + `game/`)

Read-only audit of `upstream`. Numbers from `wc -l` and a
per-file parse of `impl Game` methods, cross-referenced against call sites in `game.rs`.

**LOC correction up front:** the brief says 650k LOC / 936 files for this slice. Actual:
**324,206 LOC in 467 files** (`game.rs` 18,374 + `game/` 305,832 in 466 files, 403 top-level
modules). 650k is the *whole* `horizon-client` crate (621,814 LOC), which also holds `src/lan/`
(37,718), the reusable client systems and the renderer. Plan with ~324k, not 650k.

## 0. How the loop actually runs (read this before planning any cut)

There is no `fn run` in this tree. The real loop:

| stage | where |
|---|---|
| CLI, options, entry | `game.rs:17555 fn run_with`, `17491 fn run_loading`, `src/entry.rs` |
| event loop | `game/window_handler.rs:101 fn idle` → `about_to_wait` |
| **frame** | `game.rs:16209 WindowEvent::RedrawRequested` (inside `fn handle_window_event_inner`, `game.rs:14991`) |
| per frame | `update_world` (`14679`) · `spawn_player` (`game/player_spawn.rs:6`) · `clock.advance` · `tick()` (`7564`) · `render()` (`13750`) |
| **world tick** | `tick()` → (`remote? tick_remote`) else `tick_world()` (`7662`), 90 calls |
| **render** | `render()` → `render_frame()` (`13756`–`14541`) |
| save | `save_game_with` (`13658`), autosave in `tick()` (`7625`–`7634`) |

The single most important fact for this fork:

> **Single player is a one-client LAN server.** `game/integrated.rs` starts a second `Game`
> (`serving`) on a "Server thread"; the window joins it through
> `lan::Lan::connect_local()` → `horizon_protocol::connection::Pipe` → a `horizon-local-conn`
> thread doing a real login handshake (`integrated.rs:797-870`, `lan/mod.rs:783`). The window's
> `Game` has `remote: Some(..)` and therefore runs `tick_remote()` (`remote.rs:6505`), never
> `tick_world()`. Block breaking, placing, inventory clicks and chat all travel as
> `Clientbound*`/`Serverbound*` packets before they reach gameplay code.

So `remote.rs` (13.4k), `lan.rs` (4.2k), `lan_actions.rs` (6.9k), `lan_*.rs` (≈4.5k),
`integrated.rs` (1.4k) and `levels.rs` (0.9k) are **not multiplayer code — they are the game
loop**. `238` `self.remote.is_some()` branches and `80` `self.serving` branches sit inside
gameplay code. That is the fork's central architectural decision, and it dwarfs any feature cut.

---

## 1. Inventory

### 1.1 Totals

| verdict | files | LOC | share |
|---|---:|---:|---:|
| CORE | 230 | 151,573 | 49% |
| GATE | 51 | 52,053 | 17% |
| CUT | 183 | 87,859 | 29% |
| REWRITE | 2 | 14,813 | 5% |

(Totals are 306,298, i.e. one line per file above `wc -l`, which counts newlines. Same basis
throughout; treat every per-file figure as `wc -l`+1.)

### 1.2 By family

`CUT` = delete. `GATE` = keep, compile out behind a cargo feature. `CORE` = the game needs it.
`REWRITE` = load-bearing today, but replaced wholesale if you take the in-frame path (§3.3).

| family | files | LOC | verdict mix (LOC) |
|---|---:|---:|---|
| Gameplay core | 257 | 154,605 | CORE 130,466 · CUT 12,236 · GATE 11,903 |
| Native mod API | 78 | 37,541 | CUT 37,541 |
| Commands | 23 | 22,022 | GATE 22,022 |
| Single-player transport | 4 | 13,455 | CORE 12,045 · REWRITE 1,410 |
| Remote client | 1 | 13,403 | REWRITE 13,403 |
| LAN/guest glue | 17 | 10,294 | CORE 8,391 · CUT 1,903 |
| Agent / dev tooling | 15 | 9,188 | CUT 9,188 |
| Controllers | 12 | 7,723 | CUT 7,723 |
| Progress (adv/stats/board) | 5 | 6,574 | GATE 6,574 |
| GameTest / master blocks | 10 | 5,713 | GATE 3,391 · CUT 1,651 · CORE 671 |
| MP-only UI | 10 | 5,292 | CUT 5,292 |
| Dedicated server | 6 | 5,094 | CUT 5,094 |
| Debug overlay | 5 | 3,090 | GATE 3,090 |
| Datapack fns/cmd blocks | 2 | 3,018 | GATE 3,018 |
| Splitscreen | 7 | 2,818 | CUT 2,818 |
| Horizon extras | 6 | 2,464 | CUT 2,464 |
| Cosmetics/emotes | 4 | 1,949 | CUT 1,949 |
| Shader packs/light | 3 | 1,360 | GATE 1,360 |
| Tutorial | 1 | 695 | GATE 695 |

### 1.3 What each family is

- **Gameplay core (154.6k, 257 files)** — the vanilla game: mobs (`creatures.rs` 9.8k), world
  state, entities, block entities, items in hand, GUIs, redstone-adjacent blocks, save/load.
  12.2k of it is test/fixture files miscounted here (`*_tests.rs`, `*_fixture.rs`).
- **Native mod API (37.5k, 78 files)** — `native_hooks.rs` (13.4k, 615 hook methods) plus 77
  `native_*.rs` shims for NeoForge-style mods. Zero vanilla value at runtime.
- **Commands (22.0k, 23 files)** — `commands.rs` dispatch + `commands/*` implementations +
  `functions.rs` + `command_blocks.rs`. Only 14 lines of `game.rs` call into it.
- **Single-player transport (13.5k: `lan.rs`, `lan_actions.rs`, `integrated.rs`, `levels.rs`) +
  LAN/guest glue (10.3k of `lan_*`)** — see §0. `lan_actions.rs` is where the local player's
  body is ticked (`tick_guests`).
- **Agent / dev tooling (9.2k)** — `horizon-ctl` command surface, replay, input tracing,
  headless harnesses.
- **Controllers (7.7k)** and **Splitscreen (2.8k)** — Horizon extras, pure addition.
- **Progress (6.6k)** — advancements/stats/scoreboard; 134 trigger sites in gameplay code.
- **Dedicated server (5.1k)** — plus the separate `horizon-server` crate (19.8k).
- **MP-only UI (5.3k)** — dialogs, Code of Conduct, server resource packs, server links, social
  screen, friends, `/tempban`, chat filter, PvP page. All inert in single player.
- **Debug overlay (3.1k)**, **Datapack fns/cmd blocks (3.0k)**, **Horizon extras (2.5k)**,
  **Cosmetics (1.9k)**, **Shader packs (1.4k)**, **Tutorial (0.7k)**.

### 1.4 The 17 subdirectories of `game/` (files appear below with their path)

| dir | LOC | files | verdict |
|---|---:|---:|---|
| `commands/` | 16,546 | 22 | GATE — vanilla commands |
| `split/` | 2,502 | 7 | CUT — splitscreen |
| `dedicated/` | 2,374 | 5 | CUT — dedicated server |
| `pad/` | 2,304 | 6 | CUT — controllers |
| `machines/` | 2,226 | 4 | CORE (the 3 `native_*` files inside: CUT) |
| `scoreboard/` | 365 | 3 | GATE (tests) |
| `maps/` | 323 | 2 | CORE (tests) |
| `cosmetics/` | 321 | 1 | CUT |
| `lan_actions/` | 250 | 1 | CUT (test) |
| `lan/` | 184 | 1 | CORE (`event_timings.rs`) |
| `falling_damage/` | 170 | 1 | CORE (test) |
| `chat/` | 124 | 1 | CORE (test) |
| `ominous_item_spawner/` | 112 | 1 | CORE (test) |
| `raids/` | 109 | 1 | CORE (test) |
| `boats/` | 106 | 1 | CORE |
| `packs/` | 84 | 1 | CORE |
| `creatures/` | 68 | 1 | CORE |

---

## 2. CUT / GATE: exact edit sites

`mod` declarations are alphabetical, one per line, at `src/game.rs:52`–`467`. Every cut is
`delete the mod line(s)` + `delete the call lines below` + fix compile errors. The tables give
lines **inside the loop** first (tick / tick_world / render_frame), then the total across
`game.rs`.

### 2.1 Native mod API — CUT

Files: `game/native_hooks.rs` + all 77 `game/native_*.rs` + `game/mods.rs`, `game/mod_api_host.rs`,
`game/mod_browser.rs`, `game/block_edits.rs`, `game/machines/native_{fluids,items,energy}.rs`
(`mod native_hooks;` at `game.rs:279`, block of 78 lines). Also: `src/entry.rs` (39 `mod_api::`
references), `crates/horizon-mods`, `crates/horizon-mod-api-gen`.

| loop fn | line | call |
|---|---|---|
| tick | 7604, 7656 | `native_inventory_ticks`, `native_tick` |
| tick | 7657 | `tell_native_now` |
| tick_world | 7664, 7692, 7741, 7765 | `native_joins_flush` |
| tick_world | 7740, 7751, 7758, 7766 | `native_leaves_flush` |
| tick_world | 7753 | `tick_mod_container_viewers` |
| render_frame | 13775, 13900, 14020, 14026, 14083, 14203 | `observe_screen`, `native_camera_pose_now`, `native_frame_visuals`, `native_emissive`, `native_block_highlight`, `native_gui_render_post` |

129 `game.rs` lines total (`4174, 4185, 4191, 4238, 4311, 4365, 4434, 4569, 4651, 4725, 6168,
6481, 6667, 6727, 6882, 6952, 7085, 7188, 7230, 7296, 7525, 7992, 8036, 8148, 8172, 8208, 8260,
8310, 8375, 8450, 8582, 8604, 9343, 9456, 10047, 10318, 10533 …`).

### 2.2 Commands + datapack functions + command blocks — GATE

Files: `game/commands.rs`, `game/commands/` (22 files), `game/functions.rs`,
`game/command_blocks.rs`, `game/command_minecarts.rs`, `game/command_harness.rs`
(`mod commands;` 101, `mod functions;` 165, `mod command_blocks;` 98). Crate
`horizon-command` (11.9k) is only reachable from here.

| loop fn | line | call |
|---|---|---|
| tick | 7645 | `tick_functions` |
| tick | 7655 | `tick_command_extras` |
| update_world | 14736 | `tick_pregen` (Horizon `/pregen`) |

14 lines total: `1614, 1630, 4556, 5800, 6129, 7083, 9103, 10803, 12563, 12569, 12637, 16289`.
Plus `game/chat.rs` (command entry/registry, 52 methods) and `game/lan_chat.rs`,
`game/lan/commands.rs`, `game/scoreboard.rs` (criteria), `game/bossbars.rs` (`/bossbar`).

### 2.3 Agent / dev tooling — CUT

`game/agent.rs` (2.3k, **zero** call sites — fully self-contained island), `agent_navigation.rs`,
`agent_settings.rs`, `control.rs`, `ui_control.rs`, `events.rs`, `blockctl.rs`,
`render_control.rs`, `saves_control.rs`, `station_control.rs`, `tick_profile.rs`, `memory.rs`,
`repro.rs`, `input_trace.rs`, `tick_script.rs`, `net_harness.rs`, `command_harness.rs`,
`dispense_fixture.rs`, `sculk_fixture.rs`, `*_fixture.rs`, `no_resources.rs`, `headless.rs`,
`screenshot_sequence.rs`.

| loop fn | line | call |
|---|---|---|
| tick | 7592 | `repro_tick` |
| frame | 16265 | `tick_script_step` |
| event loop | `window_handler.rs:147` | `poll_control` |

Also `--control`/`--control-socket` in `Options::read` (`game.rs:843`, `924`) and the
`horizon-ctl` half in `horizon-client-lib`.

### 2.4 Controllers + splitscreen — CUT

`game/pad.rs`, `pad_menu.rs`, `pad_craft.rs`, `pad_actions.rs`, `game/pad/` (4 files),
`game/split.rs` + `game/split/` (7 files, 2.8k). `--no-default-features` already drops gilrs;
the game-side pad/split code does not.

| loop fn | line | call |
|---|---|---|
| render_frame | 13778 | `drop_left_screen_focus` |
| — | 6485, 7872, 8261–8289, 8603, 15107–15360, 15499–15554, 16295 | `poll_pads`, `pad_look`, `pad.*` (19 lines) |

Splitscreen: `game.rs:735` (`split::launcher::read_now`), `2539` (`split_hud` field), `7903`
(`draw_split_hud`), `13022` (`paced_by_split`), `14599` (`split_guest`), plus `App::Ready(Split)`
in `run_loading` and the `Game::new` flags at `613-620`. Careful: `split.rs:78` owns
`exit_on_error`, the *general* error path called at `15212` and `16485` — move it out before
deleting the module.

### 2.5 Progress: advancements / stats / scoreboard — GATE

`game/advancements.rs` (3.1k, **134** `self.adv` sites in gameplay), `advancements_screen.rs`,
`stats.rs` (66), `stats_screen.rs`, `scoreboard.rs`.

| loop fn | line | call |
|---|---|---|
| tick | 7644 | `load_scoreboard` |
| tick_world | 7826 | `publish_boss_bars` (scoreboard-driven boss bars) |

66 lines: `4363, 4661, 4964, 5893, 6108, 6159, 6444, 6560, 6580, 6761, 6868, 6896, 6908, 6975,
7046, 7066, 7177, 7228, 7334, 7898, 7943, 8244, 8279, 9212, 9255, 9459, 10577, 10634, 10800,
10942, 11680, 11703, 11895, 11983, 12086, 12103, 12127, 12168, 12204, 12651, 13432, 13680 …`.
These are *trigger* calls sprinkled through mining, crafting, killing, breeding — gating means
deleting the call, not just the module.

### 2.6 Debug overlay — GATE

`debug_keys.rs`, `debug_lines.rs`, `debug_options.rs`, `debug_renderers.rs`, `debug_stick.rs`,
`debug_charts` (in `debug_keys.rs`).

| loop fn | line | call |
|---|---|---|
| tick | 7572, 7573 | `tick_debug_keys`, `tick_debug_charts` |
| render_frame | 14007, 14052, 14503 | `debug_gizmos`, `debug_crosshair`, `debug_lists_gpu_passes` |

17 lines total (`6455, 6964, 7869, 7985, 8255, 9773, 15089, 15447, 15601, 15838, 15841, 16039`).

### 2.7 Shader packs / custom sky / dynamic lights — GATE

`shader_packs.rs` (1.2k), `custom_sky.rs`, `dynamic_lights.rs`; crate `horizon-shaders` (23.8k),
`horizon-shader-api`, `native_shaders.rs` (already in the native cut).

| loop fn | line | call |
|---|---|---|
| render_frame | 14275, 14318, 14324 | `custom_sky_frame`, `gather_dynamic_lights`, `shader_pack_inputs` |

32 lines total (`9600, 9727, 9733, 9738, 9746, 9765, 9778, 9997, 10054, 10140, 10207, 10286, 12832 …`).

### 2.8 Dedicated server — CUT

`game/dedicated.rs` (2.7k) + `game/dedicated/{status,report,management,transfer,events}.rs`
(2.4k). No `game.rs` call sites at all: gated only by `options.dedicated` at
`game.rs:4573, 13545, 13558, 13664, 17667, 17699` and `execution_role.rs`. Plus
`crates/horizon-server` (19.8k), `horizon-server-files`, `horizon-anticheat`, `horizon-chat-filter`.

### 2.9 MP-only UI, extras, cosmetics, tutorial

| cut | files | game.rs lines |
|---|---|---|
| dialogs / CoC / server packs / links / social / friends / tempban / chat filter / pvp | 10 files, 5.3k | 42 lines: `7351, 7849–7861, 7945–7954, 8247–8252, 8281, 10873, 13130, 15434, 15519, 15568, 15622–15637, 15853–15865, 16033` |
| studio / extras / tweaks / hud_editor / gamemode_switcher / launch_api | 6 files, 2.5k | 17 lines: `8046, 8241, 8256, 8572, 14683, 15450, 15587, 15604, 15749–15763, 15847, 16292, 16296` |
| cosmetics / emotes / emote_wheel (+`cosmetics/fx.rs`) | 4 files, 1.9k | 4 lines: `8242, 9764, 10808, 15315` |
| tutorial | 1 file, 695 | `7574`, + `tutorial_toasts` in HUD |
| LAN screens (`lan_screen.rs`, the *only* cuttable LAN piece) | 1 file, 1.9k | 6 lines: `8247, 15453, 15595, 15832, 15859, 16027` |

Of all of the above, the cargo feature `horizon-extras` currently gates **four lines**:
`game.rs:17632`, `game.rs:17637` (official/partner servers in the list) and
`game/cosmetics.rs:440`, plus `entry.rs:17`. Everything else must be cut by hand.

---

## 3. The walking skeleton

The minimum to load a world → render terrain → move → break/place → inventory → save.

### 3.1 Modules (77 files, 83,947 LOC as the code stands)

| capability | modules |
|---|---|
| **load world** | `world_entry` 381, `world_session` 256, `world_loading` 908, `integrated` 1,410, `levels` 924, `persist` 3,973, `saving` 281, `autosave` 98, `initial_spawn` 382, `player_spawn` 124, `resource_load` 629 |
| **render terrain** | `update_world` + `render_frame` (in `game.rs`), `render_tick` 673, `item_draw` 804, `screen_backgrounds` 178, `perspective` 1,854, `fov` 281, `occlusion_culling` 2,266 (perf only) |
| **move player** | `play_input` 408, `play_keys` 297, `pointer_capture` 333, `key_focus` 547, `game_mode` 258 |
| **break / place** | `hand` 1,086, `item_use` 686, `using_item` 247, `item_actions` 203, `consume` 445, `block_items` 432, `block_entity_ticks` 287, `block_entity_anims` 1,006 |
| **inventory / hotbar** | `inventory_input` 517, `inventory_slots` 378, `creative_screen` 453, `creative_hotbar` 100 (+ menu engine in `horizon-client-lib`) |
| **save world** | `persist` (already above), `saving`, `autosave`, `world_session` + `horizon_client::save` |
| **entities/mobs** | `entity` 2,151, `ordered_tick` 304, `mob_index` 90, `item_areas` 320, `creatures` 9,768, `natural_spawning` 1,186, `spawner` 699 |
| **transport (current arch)** | `remote` 13,403, `lan` 4,205, `lan_actions` 6,916, `lan_entities` 994, `lan_particles` 1,137, `lan_crafting` 1,123, `lan_stations` 904, `lan_trading` 493, `lan_vehicles` 792, `lan_mobs` 603, `lan_pvp` 696, `lan_attributes` 399, `lan_camera` 263, `lan_mount_menu` 233, `lan_waypoints` 99, `lan_idle` 155, `lan_far` 80, `remote_chunks` 479, `remote_objects` 539, `remote_projectiles` 1,037, `remote_vehicles` 960, `remote_mob_data` 1,500, `remote_camera` 159, `remote_stations` 157, `remote_chat` 538, `remote_mob_particles` 127 |
| **UI shell** | `screens` 979, `options` 781, `packs` 706, `window_handler` 304, `event_loop` 65, `loading_screen` 529, `startup_menu` 1,511, `chat` 2,695, `music` 417, `narrator` 345 |

`game.rs` itself contributes ~12–14k of that (tick, render, `use_hand`, `break_block`,
`tick_mining`, `menu_ops`, `click_inventory`, `update_world`, world open/close).

### 3.2 The transport tax

**37.0k LOC (44%) of the skeleton is transport that exists only because single player is a
server** (`remote.rs` 13.4k + `remote_*` 5.5k + `lan*` 18.1k). The same skeleton in-frame is
≈47k. Nothing else in this slice offers a 37k win.

### 3.3 The strategic fork: in-frame vs keep the hub

`--in-frame` / `--no-server-thread` were removed; `game.rs:847` prints a notice and ignores them.
The old in-frame path is gone from the tree (`repro.rs:543` says so too).

- **Option A (recommended for phase 1): keep the hub.** Cut features around it. Cheap and safe,
  but you carry the protocol forever and every gameplay fix has two sides.
- **Option B: port single player back to in-frame.** One `Game` ticks its own world: `tick()`
  calls `tick_world()` directly, `break_block`/`use_hand`/`menu_ops` act locally, `remote.rs`
  keeps only the render-side state application. Deletes ≈ `remote.rs` minus visuals,
  `lan*.rs`, `integrated.rs`, most of `src/lan/` (37.7k) and `horizon-protocol`'s play stack.
  Estimate 250–400 h, HIGH risk; the in-tree `game/*_tests.rs` / `*_fixture.rs` modules
  (11.4k LOC) assume the server thread and need re-pointing first.

---

## 4. Highest-value removals, ranked

Hours are for a clean removal (delete, fix compile, prune Cargo deps, re-run harnesses),
not for porting replacements.

| # | removal | LOC (game/) | + crates | loop edits | risk | hours |
|---|---|---:|---|---:|---|---:|
| 1 | **Native mod API** (`native_*`, `mods`, `mod_api_host`) | 37,541 | +9.9k (`horizon-mods`, `mod-api-gen`) | 17 | MED — 39 refs in `entry.rs`, hooks interpose on `use_hand`/`break_block`; `lan/hub` also calls `mod_api` | 40–60 |
| 2 | **Commands + datapack functions + command blocks** | 22,022 | +11.9k (`horizon-command`) | 3 | MED — `chat.rs` owns the registry; `/` handling, signs, command blocks, `lan/commands.rs` | 30–45 |
| 3 | **Agent / dev tooling + harnesses** | 9,188 | — | 2 | LOW — `agent.rs` has zero call sites; `--control` is opt-in | 10–16 |
| 4 | **Controllers + splitscreen** | 10,541 | +lib `gamepad` | 24 | LOW–MED — splitscreen touches window creation & the second `Game` | 12–20 |
| 5 | **Advancements + stats + scoreboard** | 6,574 | — | 66 | MED — 134 trigger calls inside gameplay; scoreboard read by `persist.rs` teams | 20–30 |
| 6 | **Multiplayer-only UI surfaces** | 5,292 | +`horizon-friends` 4.7k | 42 | LOW — inert in SP, but touches `Screen` enum and HUD draws | 8–12 |
| 7 | **Dedicated server** | 5,094 | +`horizon-server` 19.8k, `-files`, `-anticheat`, `-chat-filter` | 7 | LOW — no gameplay call sites | 6–10 |
| 8 | **Debug overlay (F3 kept, extras cut)** | 3,090 | — | 17 | LOW | 8–12 |
| 9 | **GameTest + master blocks (structure/jigsaw/test)** | 5,713 | — | 8 | MED — `tick_game_tests` is unconditional in `tick_world`; tests depend on it | 15–25 |
| 10 | **Sculk** | 2,723 | +`horizon-world` sculk | 4 | HIGH — 85 `self.sculk` sites, `with_player_actor` wraps `break_block`, game-event bus | 20–30 |
| 11 | **The End + dragon + raids** | 9,228 | worldgen | 12 | HIGH — `levels.rs` parks per-dimension state (48 fields), portals, `tick_end` in loop | 30–45 |
| 12 | **Horizon extras + cosmetics + studio** | 4,413 | +`horizon-cosmetics` 6.3k | 20 | LOW — `horizon-extras` feature already exists | 6–10 |
| 13 | **Shader packs / custom sky / dynamic lights** | 1,360 | +`horizon-shaders` 23.8k | 3 | LOW | 8–12 |
| 14 | **Tutorial** | 695 | — | 1 | LOW | 2–4 |

Total of 1–14: **≈ 123.5k LOC in `game/` plus ≈ 76k in crates.** Realistically 200–330 h.
Phases: 3+6+7+12+13+14 (≈ 25k, ~40 h, LOW risk) → 1+2 (≈ 60k, ~90 h, MED) →
4+5+8+9 (≈ 26k, ~70 h) → 10+11 (≈ 12k, ~70 h, HIGH, probably not worth it for Lite).

Two things **not** worth cutting for LOC: per-mob files (all <700 LOC each, deep vanilla
behaviour) and per-block behaviour (`beacon`, `loom`, `cartography`, `composter`, `cauldrons`,
`jukebox`, `campfire` — 3–4k total, all cheap to keep, all visible).

---

## 5. Surprises

1. **`lan*.rs` is not multiplayer.** Single player goes through the LAN hub over an in-memory
   `Pipe` with a real login handshake on its own thread (`integrated.rs:797-870`). Cutting the
   LAN code breaks single player. `lan_screen.rs` (the UI) is the only cuttable part.
2. **`remote.rs::handle_packet` is 2,015 lines and 140 match arms** (`remote.rs:3584-5599`).
   It is the single-player client. This is the biggest single function in the slice and every
   gameplay change has a client half here and a server half in `lan_actions.rs`.
3. **`break_block` (`game.rs:6446`) writes `self.lan_break_pos`** and wraps everything in
   `with_player_actor` (`sculk.rs:255`) so sculk vibrations see the right actor. The most basic
   verb in the game touches both the network layer and the sculk bus.
4. **`use_hand` (`game.rs:6713`) calls native hooks first and they can cancel the click**
   (`6727-6735`). Mod API removal is not a leaf cut: it is interposed on the primary verb.
5. **`tick_world` runs `tick_game_tests()` unconditionally** (`7823`) — `GameTestTicker.SINGLETON`
   in the shipping loop, plus `tick_functions()` and `load_scoreboard()` in `tick()`
   (`7644-7645`). Vanilla test/function machinery is in the hot path.
6. **`levels.rs` parks 48 fields per dimension** (`Parked`, lines 38–99) and imports `dragon`,
   `raids`, `sculk`, `machines`, `minecarts`, `tnt`, `trident`, `fireworks`, `lightning`,
   `ominous_item_spawner`, `creaking`, `boats`. Removing any of those means editing dimension
   switching, not just deleting a file. It is the single biggest hidden coupling after the hub.
7. **Only 20 modules are `#[cfg(...)]`-gated** (18 `cfg(test)`, 2 feature). 383 of 403 modules
   compile into the release binary unconditionally — including ~8.4k LOC of dev harnesses:
   `repro.rs` 1,973, `dispense_fixture.rs` 1,394, `command_harness.rs` 1,205,
   `sculk_fixture.rs` 810, `input_trace.rs` 676, `net_harness.rs` 157, `tick_script.rs` 132.
   Free win: `#[cfg(test)]`/`#[cfg(feature = "dev-harness")]` them.
8. **A fork path already exists and is documented**: `docs/forking.md` + Cargo feature
   `horizon-extras` (= `discord` + `friends` + `heartbeat`). Only **4 sites** use it
   (`game.rs:17632, 17637`, `entry.rs:17`, `cosmetics.rs:440`). `--no-default-features` already
   builds a "horizon-engine" server binary with no audio/controllers. Build on this, don't
   invent a parallel flag system.
9. **No dead code and no TODOs.** 0 `TODO`/`FIXME`/`unimplemented!` in 306k LOC, 15
   `#[allow(dead_code)]`. Every module is reachable. Do not expect easy wins from unused files —
   the wins are all architectural.
10. **`persist.rs` (4.0k) is the entity save format, and it reads the scoreboard** for team
    membership (line 12, 2222). Cutting scoreboard without touching `persist.rs` produces
    silently team-less reloads.
11. **`stats.rs`, `advancements.rs` and `scoreboard.rs` are not modules you delete, they are
    134+66+52 call sites you edit.** Same for sculk (85). Judge GATE candidates by call sites,
    not LOC.
12. **Two already-cut things to not resurrect**: `--in-frame`/`--no-server-thread` now only
    print a notice (`game.rs:847`), and `--headless` has a whole module (`headless.rs`).
    If you do the in-frame port (§3.3), you are re-adding a path the upstream deliberately
    deleted — budget for the parity harnesses that assume the server thread.

---

---

## Appendix A — every file

`calls` = call sites in `game.rs`. Sorted by LOC. Files in the subdirectories above keep their
path (`commands/…`, `pad/…`, `split/…`).

| path | LOC | calls | what it is | verdict |
|---|---:|---:|---|---|
| `remote.rs` | 13,403 | 26 | Multiplayer: the game driven by a server connection instead of the local | **REWRITE** |
| `native_hooks.rs` | 13,392 | 98 | Hook points for native mods : empty | **CUT** |
| `creatures.rs` | 9,768 | 19 | Mobs in the game loop: ticking with entity snapshots, natural and | **CORE** |
| `lan_actions.rs` | 6,916 | 3 | What guests do in a hosted world | **CORE** |
| `dragon.rs` | 5,692 | 3 | The ender dragon fight (EnderDragonFight, EnderDragon, its phases, | **GATE** |
| `commands.rs` | 5,454 | 9 | Command execution (the execute side of each vanilla command class): | **GATE** |
| `lan.rs` | 4,205 | 13 | Hosting the open world on the local network ("Open to LAN"): starts the | **CORE** |
| `persist.rs` | 3,973 | 8 | Saving and loading the game state that lives outside chunk blocks: | **CORE** |
| `minecarts.rs` | 3,541 | 5 | Minecarts (AbstractMinecart with OldMinecartBehavior): following | **CORE** |
| `stations.rs` | 3,246 | 28 | Workstation menus in the game: enchanting table, anvil, grindstone, | **CORE** |
| `advancements.rs` | 3,119 | 21 | The player's advancements in the game: criteria triggered from game | **GATE** |
| `potions.rs` | 3,090 | 13 | Potions and status effects in the game: drinking (PotionItem via | **CORE** |
| `pad_menu.rs` | 2,723 | 14 | A controller in menus, screens and inventories (Horizon's own; | **CUT** |
| `sculk.rs` | 2,723 | 32 | Game events and sculk on the game side: dispatching events to sculk | **GATE** |
| `commands/world_cmds.rs` | 2,722 | 0 | /recipe, /damage, /rotate, /swing, /playsound, /stopsound, | **GATE** |
| `dedicated.rs` | 2,715 | 0 | The dedicated server (net.minecraft.server.Main and DedicatedServer): | **CUT** |
| `chat.rs` | 2,695 | 14 | Chat, the command registries and the per-world state behind commands | **CORE** |
| `dispenser.rs` | 2,304 | 4 | Dispenser behaviours: DispenserBlock.getDispenseMethod(..).dispense with | **CORE** |
| `occlusion_culling.rs` | 2,266 | 2 | Shared, conservative block-occlusion queries for renderable geometry | **CORE** |
| `agent.rs` | 2,265 | 0 | Control-socket commands for agents and scripts that play the game: read | **CUT** |
| `commands/items.rs` | 2,225 | 1 | /item (ItemCommands) and if items/if slots: addressing the item | **GATE** |
| `fishing.rs` | 2,199 | 6 | Fishing: FishingRodItem.use (cast / reel in), the FishingHook (flight, | **CORE** |
| `commands/data.rs` | 2,173 | 0 | /data (DataCommands), /tag (TagCommand) and /summon with NBT: entity, | **GATE** |
| `maps.rs` | 2,160 | 11 | Maps (EmptyMapItem, MapItem, MapItemSavedData, MapRenderer): | **CORE** |
| `entity.rs` | 2,151 | 4 | Entity: what every kind in the game's entity lists answers to, so a system | **CORE** |
| `armor_stands.rs` | 2,094 | 5 | Armor stands: ArmorStandItem.useOn placement (snapped to 45 degrees), | **CORE** |
| `boats.rs` | 2,011 | 4 | Boats and rafts (AbstractBoat): water/land/air status, floating, | **CORE** |
| `repro.rs` | 1,973 | 1 | Repro recordings : a session's input, tick-stamped | **CUT** |
| `functions.rs` | 1,914 | 1 | Data packs in the game: functions (/function, /return, tick and load | **GATE** |
| `machines.rs` | 1,906 | 5 | Item-moving blocks: HopperBlockEntity (push, pull, item entities, | **CORE** |
| `lan_screen.rs` | 1,903 | 6 | WorldOptionsScreen: the in-world options with the multiplayer section | **CUT** |
| `perspective.rs` | 1,854 | 13 | The camera type (CameraType: first person, third person behind and | **CORE** |
| `native_server.rs` | 1,845 | 0 | Server commands and players for native mods (docs/native-mods.md, | **CUT** |
| `recipe_book.rs` | 1,832 | 7 | The recipe book of the inventory, crafting table and furnace screens | **CORE** |
| `end.rs` | 1,818 | 11 | The End: End portal frames filled with eyes of ender, End portal and End | **GATE** |
| `tnt.rs` | 1,798 | 3 | Primed TNT (PrimedTnt): 80-tick fuse, gravity and drag, explosion of | **CORE** |
| `control.rs` | 1,743 | 3 | Commands from the control socket (horizon-ctl), run on the game thread | **CUT** |
| `raids.rs` | 1,670 | 1 | Pillager patrols (PatrolSpawner), the raid omen, and raids (Raids): | **GATE** |
| `game_tests.rs` | 1,651 | 1 | The game-test runner: GameTestInfo, GameTestRunner, GameTestTicker, | **CUT** |
| `books.rs` | 1,592 | 7 | Books (BookEditScreen, BookSignScreen, BookViewScreen, | **CORE** |
| `commands/execute.rs` | 1,587 | 0 | /execute (ExecuteCommand): walk the parsed redirect chain, forking and | **GATE** |
| `explosion.rs` | 1,576 | 4 | ServerExplosion: exploded positions (vanilla ray march over a Java | **CORE** |
| `enchant_effects.rs` | 1,515 | 14 | Enchantment effects on gameplay, read from the data-driven effect | **CORE** |
| `startup_menu.rs` | 1,511 | 0 | The interactive title before world resources exist | **CORE** |
| `mounts.rs` | 1,505 | 4 | Riding horses, donkeys and mules: feeding (handleEating), saddles, | **CORE** |
| `remote_mob_data.rs` | 1,500 | 0 | A server's mobs as their synched data has them | **CORE** |
| `nether_portal.rs` | 1,476 | 7 | Nether portals for the player and the other entities: | **CORE** |
| `commands/terrain_cmds.rs` | 1,473 | 1 | /forceload, /fillbiome, /worldborder and /loot | **GATE** |
| `debug_keys.rs` | 1,428 | 8 | The debug keys in the game (26.3 KeyboardHandler.keyPress, | **GATE** |
| `integrated.rs` | 1,410 | 1 | The integrated server (IntegratedServer): single player's world runs on | **REWRITE** |
| `dispense_fixture.rs` | 1,394 | 0 | The Rust side of tools/test_dispenser_parity.py: with | **CUT** |
| `commands/extra.rs` | 1,308 | 1 | Commands that act on the player and the hosted game rather than the world: | **GATE** |
| `names.rs` | 1,307 | 1 | Custom names: NameTagItem.interactLivingEntity and the name tag | **CORE** |
| `server_travel.rs` | 1,265 | 0 | A server's players between dimensions | **CORE** |
| `machines/native_fluids.rs` | 1,259 | 0 | Fluids of a block for native server mods : | **CUT** |
| `trident.rs` | 1,246 | 5 | Tridents: TridentItem.releaseUsing (throw after 10 ticks, or Riptide in | **CORE** |
| `command_harness.rs` | 1,205 | 0 | Headless command runner for tools/test_command_exec_parity.py: with | **CUT** |
| `scoreboard.rs` | 1,202 | 4 | The scoreboard in the running game: saved data, criteria that follow the | **GATE** |
| `dialogs.rs` | 1,200 | 14 | A server's dialogs bound to the game (ClientCommonPacketListenerImpl | **CUT** |
| `native_block_entity_draw.rs` | 1,187 | 2 | Mod block entities drawn on the client: native_block_entity_submit | **CUT** |
| `natural_spawning.rs` | 1,186 | 0 | The game's side of NaturalSpawner (mobs::spawn_selection): the level | **CORE** |
| `cosmetics.rs` | 1,181 | 0 | Cosmetics on players ): only Horizon | **CUT** |
| `shader_packs.rs` | 1,164 | 30 | Shader packs: the one picked on Options > Horizon Settings > Shader Packs… | **GATE** |
| `lan_particles.rs` | 1,137 | 6 | Particles a server sends its players and its clients draw: | **CORE** |
| `piston_push.rs` | 1,132 | 2 | PistonMovingBlockEntity.moveCollidedEntities and moveStuckEntities for | **CORE** |
| `lan_crafting.rs` | 1,123 | 1 | Crafting for LAN guests: the inventory's 2x2 grid (window 0) and the | **CORE** |
| `command_blocks.rs` | 1,104 | 10 | Command blocks: CommandBlock's placement (setPlacedBy), its scheduled | **GATE** |
| `hand.rs` | 1,086 | 39 | The local player's hand: clicks and held attack through | **CORE** |
| `spill.rs` | 1,041 | 1 | Block entities removed by the block behaviour (LevelChunk.setBlockState | **CORE** |
| `remote_projectiles.rs` | 1,037 | 1 | Primed TNT, falling blocks, projectiles, tridents, firework rockets and | **CORE** |
| `leads.rs` | 1,026 | 2 | Leads on the game side: putting them on and taking them off mobs | **CORE** |
| `block_entity_anims.rs` | 1,006 | 9 | The client side of animated block entities (horizon_client::block_entity_… | **CORE** |
| `mods.rs` | 998 | 1 | Mods in the game : content mods' blocks, items, data and | **CUT** |
| `lan_entities.rs` | 994 | 0 | The entities beyond mobs and items that a server tracks to its clients | **CORE** |
| `screens.rs` | 979 | 7 | The pause menu (PauseScreen) and death screen (DeathScreen) layouts | **CORE** |
| `remote_vehicles.rs` | 960 | 0 | Boats, minecarts, item frames, armor stands and paintings for a server's | **CORE** |
| `studio.rs` | 951 | 1 | In-game Video Studio: Recording & Replay Subsystem | **CUT** |
| `trading.rs` | 942 | 3 | The merchant (villager trading) menu: MerchantMenu / MerchantScreen | **CORE** |
| `split.rs` | 929 | 2 | Splitscreen (in parts; #3541): more players on this computer in P1's worl… | **CUT** |
| `levels.rs` | 924 | 2 | A server's levels, one per dimension (MinecraftServer.levels) | **CORE** |
| `lightning.rs` | 920 | 3 | Lightning (ServerLevel.tickThunder, LightningBolt, | **CORE** |
| `pad_craft.rs` | 913 | 0 | Crafting a recipe straight into the inventory with a controller (Horizon'… | **CUT** |
| `sign_edit.rs` | 909 | 8 | The sign editing screen (SignEditScreen / HangingSignEditScreen): | **CORE** |
| `world_loading.rs` | 908 | 0 | Prepare local worlds without blocking the window's event loop | **CORE** |
| `lan_stations.rs` | 904 | 0 | Workstation menus for LAN guests: the screen a guest's use opens runs on | **CORE** |
| `native_client_services.rs` | 892 | 0 | Client services for trait mods, without exposing Game or the atlas | **CUT** |
| `fireworks.rs` | 890 | 4 | Firework rockets (FireworkRocketItem, FireworkRocketEntity): launching | **CORE** |
| `dedicated/management.rs` | 871 | 0 | The management protocol's list edits, which horizon-server forwards on th… | **CUT** |
| `native_panel.rs` | 862 | 7 | The item panel beside container screens: the items a recipe viewer mod | **CUT** |
| `pad.rs` | 852 | 2 | Controllers through gilrs (Horizon's own; docs/controllers.md): the | **CUT** |
| `pad/hardware.rs` | 844 | 0 | The real controllers (the controllers feature): gilrs' pads, and the Dual… | **CUT** |
| `mob_blocks.rs` | 839 | 0 | Blocks mobs carry: block items in a hand (ItemInHandLayer) and the | **CORE** |
| `frames.rs` | 836 | 3 | Item frames and glow item frames: ItemFrameItem placement on any face, | **CORE** |
| `block_edits.rs` | 829 | 0 | A server mod's bulk block edit (native_edit_blocks): its palette and | **CUT** |
| `combat.rs` | 829 | 0 | The player's CombatTracker: the damage taken lately, who dealt it and | **CORE** |
| `advancements_screen.rs` | 811 | 4 | The Advancements screen (AdvancementsScreen, AdvancementTab, | **GATE** |
| `bossbars.rs` | 811 | 2 | /bossbar (BossBarCommands) and drawing the custom boss bars | **CORE** |
| `sculk_fixture.rs` | 810 | 0 | The Rust side of tools/test_sculk_parity.py: with | **CUT** |
| `item_draw.rs` | 804 | 5 | Items drawn through the resolved item model pipeline | **CORE** |
| `stats_screen.rs` | 802 | 5 | The Statistics screen (StatsScreen): General, Items and Mobs tabs over | **GATE** |
| `dedicated/report.rs` | 800 | 0 | horizon-report SECONDS on the dedicated server's console (and horizon-ser… | **CUT** |
| `lan_vehicles.rs` | 792 | 1 | Boats and minecarts for a server's players: LAN guests, players on a | **CORE** |
| `particle_culling.rs` | 785 | 2 | Particle visibility checks and their worker, separate from entity culling | **CORE** |
| `options.rs` | 781 | 21 | The options screens bound to the game: drawing, input, applying settings | **CORE** |
| `native_entities.rs` | 775 | 12 | Entities for native server mods : spawn | **CUT** |
| `pvp.rs` | 765 | 5 | The PvP & HUD page's options in the game (horizon_client::pvp, docs/pvp.m… | **CUT** |
| `passengers.rs` | 758 | 0 | Mobs riding mobs: boarding and dismounting, keeping riders on their | **CORE** |
| `beacon.rs` | 742 | 1 | Beacons (BeaconBlockEntity, BeaconMenu, BeaconScreen, | **CORE** |
| `structure_blocks.rs` | 740 | 2 | Structure blocks on the server: StructureBlockEntity's save, load and | **GATE** |
| `mace.rs` | 735 | 5 | Maces (MaceItem): a hit after falling more than one and a half blocks is | **CORE** |
| `native_inventories.rs` | 720 | 0 | Another player's inventories for server mods (API 132): | **CUT** |
| `test_instances.rs` | 719 | 1 | Test instance blocks on the server: handleTestInstanceBlockAction and | **GATE** |
| `packs.rs` | 706 | 0 | Resource pack selection bound to the game: the pack screen lists, and a | **CORE** |
| `spawner.rs` | 699 | 2 | Monster spawners in the game: SpawnerBlockEntity.serverTick and | **CORE** |
| `server_packs.rs` | 697 | 6 | A server's resource packs bound to the game (ClientCommonPacketListenerIm… | **CUT** |
| `lan_pvp.rs` | 696 | 0 | Players hitting players on a server (Player.attack on a player) | **CORE** |
| `tutorial.rs` | 695 | 0 | Client tutorial progression (net.minecraft.client.tutorial) | **GATE** |
| `cushions.rs` | 691 | 3 | Cushions: CushionItem.useOn placement on the top face of a block, | **CORE** |
| `wind.rs` | 691 | 1 | Wind charges: the item a player throws (WindChargeItem), the charges | **CORE** |
| `native_menus.rs` | 688 | 0 | Server menus for native mods (docs/native-mods.md, "Server menus", API | **CUT** |
| `item_use.rs` | 686 | 4 | LivingEntity.startUsingItem and the use over time of items vanilla's | **CORE** |
| `split/windows.rs` | 682 | 0 | Windows and monitors: which window each player plays in, opening and plac… | **CUT** |
| `input_trace.rs` | 676 | 0 | Who caused an input event: a person at the keyboard (user), an agent on t… | **CUT** |
| `split/players.rs` | 675 | 0 | Players coming and going: joining (P1's world through memory, or P1's ser… | **CUT** |
| `render_tick.rs` | 673 | 6 | Per-tick client visuals: the particle engine, ClientLevel.animateTick, | **CORE** |
| `block_editor.rs` | 671 | 5 | The edit screens of the game master blocks (StructureBlockEditScreen, | **CORE** |
| `pad/guide.rs` | 653 | 3 | The gameplay guide in the game (gameplay_guide): the facts it resolves, r… | **CUT** |
| `mount_menu.rs` | 643 | 11 | The horse inventory (HorseInventoryMenu, HorseInventoryScreen): the | **CORE** |
| `entity_culling.rs` | 641 | 2 | Entity mesh occlusion and view-distance checks | **CORE** |
| `stats.rs` | 640 | 32 | Player statistics (ServerStatsCounter): the custom counters, blocks | **GATE** |
| `paintings.rs` | 638 | 3 | Paintings: HangingEntityItem.useOn placement with Painting.create's | **CORE** |
| `resource_load.rs` | 629 | 0 | The startup's resource load: the stages the loading screen shows, the | **CORE** |
| `jukebox.rs` | 625 | 4 | Jukeboxes (JukeboxBlock, JukeboxBlockEntity, JukeboxSongPlayer): | **CORE** |
| `split/pads.rs` | 620 | 0 | Controllers: which player each drives, joining with one, and one disconne… | **CUT** |
| `debug_options.rs` | 615 | 6 | DebugOptionsScreen (F3+F6): every debug entry with Off / In Overlay / | **GATE** |
| `vehicle_teleport.rs` | 607 | 0 | The writers /tp and /rotate share with a vehicle's riders: a vehicle | **CORE** |
| `crossbow.rs` | 604 | 3 | Crossbows (CrossbowItem): charging with the start/middle/end sounds | **CORE** |
| `lan_mobs.rs` | 603 | 4 | Mobs and the guests of an open world | **CORE** |
| `boat_leads.rs` | 602 | 0 | Leads on boats and rafts (AbstractBoat implements Leashable): putting a | **CORE** |
| `piglins.rs` | 598 | 5 | The game side of piglins (PiglinAi): spotting and picking up gold, | **CORE** |
| `server_links.rs` | 596 | 7 | ServerLinksDialogScreen: the pause menu's "Server Links..." button opens | **CUT** |
| `villagers.rs` | 593 | 1 | What villagers do with each other and with the player: gossip and | **CORE** |
| `commands/profiles.rs` | 592 | 0 | /op, /deop, /ban, /pardon, /ban-ip, /pardon-ip, /banlist, | **GATE** |
| `native_panel_recipes.rs` | 589 | 0 | A mod's recipes shown in its item panel's place (native_panel_recipes, | **CUT** |
| `text_displays.rs` | 588 | 2 | Server text displays: metadata, interpolation, billboard transforms and w… | **CORE** |
| `debug_lines.rs` | 582 | 0 | The F3 overlay's text entries (26.3 DebugEntry*): what each enabled | **GATE** |
| `core_tests.rs` | 581 | 0 | Unit tests that lived in game.rs's inline tests module | **CUT** |
| `tempban.rs` | 571 | 0 | /tempban <player> <duration> reason, a Horizon extra for dedicated server… | **CUT** |
| `respawn_anchor.rs` | 563 | 6 | RespawnAnchorBlock in the game: glowstone charges it (useItemOn), a | **CORE** |
| `storage.rs` | 552 | 15 | Shulker boxes (ShulkerBoxBlockEntity: 27 slots that refuse other boxes, | **CORE** |
| `key_focus.rs` | 547 | 0 | Vanilla's keyboard focus navigation in Horizon's menus | **CORE** |
| `tweaks.rs` | 546 | 4 | Horizon's inventory extras (#332, docs/extras.md), Mouse Tweaks-style | **CUT** |
| `commands/compute.rs` | 542 | 0 | /compute (ComputeCommand): context number providers | **GATE** |
| `remote_objects.rs` | 539 | 1 | Boats, minecarts, armor stands, item frames, paintings and fence knots on… | **CORE** |
| `chat_filter.rs` | 538 | 0 | The dedicated server's chat filter, game side : what the hub refused is | **CUT** |
| `remote_chat.rs` | 538 | 3 | Secure chat on a server's client (ClientPacketListener): the chat | **CORE** |
| `native_text_field.rs` | 532 | 1 | Focused existing text boxes, without exposing a mutable UI or queued writ… | **CUT** |
| `loading_screen.rs` | 529 | 0 | The loading screen while the resources load (Loading), the window's app b… | **CORE** |
| `boat_passengers.rs` | 526 | 0 | Boats and the entities around them: what a boat runs into | **CORE** |
| `inventory_input.rs` | 517 | 18 | Keys and mouse buttons over an open container screen: hotbar and pick key… | **CORE** |
| `structure_edit.rs` | 511 | 0 | StructureBlockEditScreen: the structure block's name, position, size, | **GATE** |
| `native_machines.rs` | 499 | 0 | What a mod's machine does to the world as a player's hand would, with no | **CUT** |
| `lan_trading.rs` | 493 | 0 | Trading for LAN guests: the villager screen a guest opens runs the same | **CORE** |
| `commands/test_runs.rs` | 490 | 0 | TestCommand over the test instance blocks of the level in place and the | **GATE** |
| `remote_mob_use.rs` | 489 | 0 | A server's client right-clicking a mob: vanilla's client runs | **CORE** |
| `native_configs.rs` | 488 | 1 | Native mods' config files, loaded and reloaded (NeoForge's ModConfig | **CUT** |
| `commands/place.rs` | 486 | 0 | /place template (PlaceCommand): a saved structure template placed with | **GATE** |
| `creaking.rs` | 486 | 1 | The creaking heart block entity in the game: mobs::creaking_heart | **CORE** |
| `native_entity_refs.rs` | 486 | 0 | Entity and level handles for native mods (docs/native-mods.md, "Entity | **CUT** |
| `potent_sulfur.rs` | 486 | 0 | Potent sulfur geysers: the tickers PotentSulfurBlock.getTicker gives | **CORE** |
| `remote_chunks.rs` | 479 | 0 | A server's chunk columns (ClientboundLevelChunkWithLightPacket): the | **CORE** |
| `native_player_state.rs` | 464 | 0 | A player's state for server mods (docs/native-mods.md, "Server hooks for | **CUT** |
| `native_recipes.rs` | 464 | 1 | Every item and recipe the game knows, made once for the mods that read | **CUT** |
| `spear.rs` | 459 | 3 | Spears (KineticWeapon): holding the use button charges the spear, and | **CORE** |
| `creative_screen.rs` | 453 | 12 | The creative inventory screen (CreativeModeInventoryScreen): its tabs, pa… | **CORE** |
| `copper_golems.rs` | 447 | 2 | Copper golems on the game side: what their brain (mobs::transport_items) | **CORE** |
| `level_particles.rs` | 447 | 25 | Level events whose client handler (LevelEventHandler) spawns particles | **CORE** |
| `consume.rs` | 445 | 2 | Finishing a consumable (Consumable.onConsume and the use remainder), | **CORE** |
| `agent_navigation.rs` | 440 | 0 |  | **CUT** |
| `block_items.rs` | 432 | 4 | Block entities and the items that carry them | **CORE** |
| `fangs.rs` | 432 | 1 | Evoker fangs (EvokerFangs): rising out of the floor after a delay, | **CORE** |
| `allays.rs` | 428 | 0 | Allays on the game side: spotting and picking up matching drops, | **CORE** |
| `beehives.rs` | 428 | 3 | Beehives and bee nests in the game (crate::beehive holds their logic): | **CORE** |
| `loading_window.rs` | 427 | 0 | The window's first renderer and frames: the renderer built from the prepa… | **CORE** |
| `machines/crafter.rs` | 417 | 3 | The crafter (CrafterBlock, CrafterBlockEntity, CrafterMenu, | **CORE** |
| `music.rs` | 417 | 7 | Minecraft.getSituationalMusic and getMusicVolume for the music manager, | **CORE** |
| `test_instance_edit.rs` | 414 | 0 | TestInstanceBlockEditScreen: the test's id, the size of the area, its | **GATE** |
| `native_data_maps.rs` | 409 | 0 | Data maps for native server mods : values a data pack | **CUT** |
| `play_input.rs` | 408 | 16 | Key and mouse mappings in play: toggled sneak and sprint, keys after rebi… | **CORE** |
| `commands/text_commands.rs` | 403 | 0 | /tellraw (TellRawCommand) and /title (TitleCommand) | **GATE** |
| `dedicated/transfer.rs` | 400 | 0 | A proxy's requests on the control endpoint, for a player it moves between… | **CUT** |
| `occlusion_culling_tests.rs` | 400 | 0 |  | **CUT** |
| `lan_attributes.rs` | 399 | 0 | The attribute instances a server syncs for the living entities it tracks | **CORE** |
| `golems.rs` | 397 | 2 | Building golems from blocks (CarvedPumpkinBlock.trySpawnGolem): a carved | **CORE** |
| `sulfur_cubes.rs` | 395 | 0 | Sulfur cubes on the game side (SulfurCube.mobInteract, pickUpItem, | **CORE** |
| `native_net.rs` | 394 | 0 | Mod messages for native mods (docs/native-mods.md, "Mod messages", API | **CUT** |
| `native_travel.rs` | 394 | 0 | Moving players and vehicles for server mods (docs/native-mods.md, "Moving… | **CUT** |
| `loom.rs` | 386 | 4 | The loom screen (LoomScreen): the scrolling pattern list, the banner | **CORE** |
| `zombie_villagers.rs` | 385 | 0 | Zombie villagers in the world: zombies turning the villagers they kill | **CORE** |
| `cartography.rs` | 384 | 2 | The cartography table (CartographyTableMenu on the menu engine, | **CORE** |
| `brush.rs` | 383 | 3 | Brushing suspicious sand and gravel: BrushItem.onUseTick and | **CORE** |
| `initial_spawn.rs` | 382 | 0 | A new world's spawn and its first player's position: MinecraftServer | **CORE** |
| `world_entry.rs` | 381 | 22 | Entering a world without blocking the window: the deferred entry, world c… | **CORE** |
| `inventory_slots.rs` | 378 | 18 | Container screen slots: item and decoration drawing, the carried stack an… | **CORE** |
| `test_environments.rs` | 376 | 0 | TestEnvironmentDefinition: what a game test batch changes in the world | **GATE** |
| `trial_spawner.rs` | 372 | 0 | Trial spawners in the game: TrialSpawner.tickServer for every trial | **CORE** |
| `native_item_container.rs` | 370 | 0 | Items held by item stacks for native mods : a mod's | **CUT** |
| `native_lifecycle.rs` | 369 | 0 | Read-only lifecycle observations for native mods on authoritative servers | **CUT** |
| `native_npcs.rs` | 366 | 0 | NPCs for native server mods (docs/native-mods.md, "Server hooks for plugin | **CUT** |
| `native_quick_move.rs` | 365 | 0 | A shift-click in a mod container's menu, routed by the mods | **CUT** |
| `events.rs` | 363 | 0 | What happened in the game, for agents (events, wait-for; docs/agent-contr… | **CUT** |
| `commands/items/contents.rs` | 360 | 0 | ContentsSlotSource's live component collections; mutable until written ba… | **GATE** |
| `native_item_fluids.rs` | 357 | 0 | Fluids held by item stacks for native mods : vanilla's | **CUT** |
| `commands/test_locate.rs` | 354 | 0 | TestCommand's locate, pos and create | **GATE** |
| `commands/misc.rs` | 348 | 1 | /random (RandomCommand) and /teammsg (TeamMsgCommand) | **GATE** |
| `trial_visuals.rs` | 346 | 1 | The client side of trial spawners and vaults: LevelEventHandler 3011 to | **CORE** |
| `narrator.rs` | 345 | 3 | The narrator (Minecraft.narrator, horizon-narrator's GameNarrator): | **CORE** |
| `native_claimed_items.rs` | 343 | 0 | A client mod's view and its own items : the | **CUT** |
| `native_item_energy.rs` | 341 | 0 | Energy held by item stacks for native mods : a mod's | **CUT** |
| `friends.rs` | 335 | 3 | Play with friends, host side: "Start Sharing" on the Play with Friends | **CUT** |
| `launch_api.rs` | 335 | 0 | The game's side of the Launch API : the options another launcher may pass, | **CUT** |
| `wither.rs` | 335 | 1 | The wither on the game side: building it (WitherSkullBlock.checkSpawn), | **CORE** |
| `jigsaw_edit.rs` | 333 | 0 | JigsawBlockEditScreen: the jigsaw block's pool, name, target, final | **GATE** |
| `pointer_capture.rs` | 333 | 11 | The mouse in play: the look it turns, the pointer grab (MouseHandler.grab… | **CORE** |
| `native_mobs.rs` | 332 | 1 | Mobs for native server mods : spawn one, | **CUT** |
| `totem.rs` | 331 | 5 | The totem of undying (LivingEntity.checkTotemDeathProtection: a hand's | **CORE** |
| `spear_players.rs` | 330 | 0 | A player's spear on the other players of a server: the charge | **CORE** |
| `native_client_world.rs` | 327 | 0 | The client world read off the game thread, for a client mod that bakes fr… | **CUT** |
| `cosmetics/fx.rs` | 322 | 1 | Companions, trails and auras ): worn | **CUT** |
| `item_areas.rs` | 320 | 0 | Where the level's dropped items lie, in 8-block cells, for the passes that | **CORE** |
| `native_shaders.rs` | 319 | 0 | Horizon's own shader packs in the game : the pick in shaderpacks/ (a | **CUT** |
| `screenshot_sequence.rs` | 318 | 1 | screenshot-sequence FRAMES STEP_MS PATH: the running shader pack starts o… | **CUT** |
| `client_ambient.rs` | 315 | 1 | The window's own ambient effects of entities, which a client makes for | **CORE** |
| `entity_model_loading_tests.rs` | 312 | 0 | Model-batch equivalence tests and an opt-in benchmark of the actual loade… | **CUT** |
| `code_of_conduct.rs` | 311 | 3 | A server's Code of Conduct bound to the game (ClientConfigurationPacketLi… | **CUT** |
| `commands/effects.rs` | 308 | 0 | /effect (EffectCommands) and /enchant (EnchantCommand) | **GATE** |
| `native_projectiles.rs` | 304 | 0 | Projectile impacts for native mods (native_projectile_impact, NeoForge's | **CUT** |
| `ordered_tick.rs` | 304 | 10 | PURPOSE: ticks experience orbs, primed TNT and falling blocks in the order | **CORE** |
| `pad_actions.rs` | 304 | 0 | The controller's side of the buttons screens declare (widgets::Action): w… | **CUT** |
| `window_handler.rs` | 304 | 0 | winit's ApplicationHandler for the game window: window and device events,… | **CORE** |
| `shield.rs` | 301 | 8 | Shields and other blocks_attacks items: raising them (ShieldItem.use, | **CORE** |
| `play_keys.rs` | 297 | 1 | A key press while a world is open (KeyboardHandler.keyPress and the gamep… | **CORE** |
| `deflect.rs` | 296 | 0 | A player's blow at a ghast's fireball or a wind charge | **CORE** |
| `debug_renderers.rs` | 293 | 1 | The debug options screen's renderer entries (26.3 DebugRenderer): the | **GATE** |
| `commands/pregen.rs` | 292 | 1 | /pregen, Horizon's own command: generate, light and save every chunk of a | **GATE** |
| `building_players.rs` | 290 | 0 | Player candidates for EntityGetter.isUnobstructed while a guest owns the | **CORE** |
| `block_entity_ticks.rs` | 287 | 1 | Level.tickBlockEntities for the block entities ticked together here | **CORE** |
| `native_visuals.rs` | 285 | 1 | What one mod's visual requests may use of a frame, whatever other mods as… | **CUT** |
| `extras.rs` | 284 | 4 | Horizon's extras in the game ; a native mod's minimap | **CUT** |
| `fov.rs` | 281 | 9 | Field of view (Camera.tickFov, calculateFov, | **CORE** |
| `saving.rs` | 281 | 2 | The save screen freezes simulation, but keeps pumping window events while | **CORE** |
| `machines/native_items.rs` | 279 | 0 | Items in a block's container for native server mods (docs/native-mods.md, | **CUT** |
| `native_scene.rs` | 279 | 0 | A few blocks drawn in a screen as a small scene seen from an angle: what | **CUT** |
| `first_tick_registration_tests.rs` | 278 | 0 | LevelChunk.registerTickContainerInLevel: a chunk's block and fluid tick | **CUT** |
| `machines/native_energy.rs` | 275 | 0 | Energy in a block's buffer for native server mods : | **CUT** |
| `ghasts.rs` | 273 | 2 | Happy ghasts on the game side: putting a harness on (and shearing it | **CORE** |
| `native_client_entities.rs` | 271 | 0 | Entities shown to one player's client alone, for native server mods | **CUT** |
| `pad/parity_tests.rs` | 269 | 0 | A controller action does what its keyboard key does, on a real Game witho… | **CUT** |
| `mod_api_host.rs` | 267 | 2 |  | **CUT** |
| `lan_camera.rs` | 263 | 0 | A spectating guest's camera (ServerPlayer.camera): chosen by a click | **CORE** |
| `native_structures.rs` | 262 | 0 | Structure templates read for server mods (vanilla's | **CUT** |
| `shelf.rs` | 261 | 2 | The displayed items of ShelfBlockEntity | **CORE** |
| `splash_water.rs` | 260 | 0 | AbstractThrownPotion: what a splash or lingering potion does around where | **CORE** |
| `game_mode.rs` | 258 | 29 | Game modes beyond survival and creative (GameType): adventure players | **CORE** |
| `vault.rs` | 257 | 2 | Vaults in the game: VaultBlockEntity.Server.tick for every vault | **CORE** |
| `agent_settings.rs` | 256 | 0 | Agent control as a setting (Horizon Settings > AI Agent): when the contro… | **CUT** |
| `hud_editor.rs` | 256 | 6 | The HUD editor : the PvP & HUD widgets on the game, each in a frame the | **CUT** |
| `native_world_draw.rs` | 256 | 1 | A native mod's world-space text and atlas quads, through the normal rende… | **CUT** |
| `world_session.rs` | 256 | 4 | Opening and closing a local world from the client: the title screen's act… | **CORE** |
| `native_diagnostics.rs` | 252 | 0 | What a server's diagnostics mod reads (docs/native-mods.md, "Server hooks | **CUT** |
| `lan_actions/crack_feedback_tests.rs` | 251 | 0 |  | **CUT** |
| `wandering_trader.rs` | 250 | 0 | WanderingTraderSpawner: every 1200 ticks the spawn delay counts down; | **CORE** |
| `tick_profile.rs` | 248 | 0 | What each kind of mob costs the server tick, for horizon-report (dedicate… | **CUT** |
| `native_bots.rs` | 247 | 0 | Server-side player bots for mods (docs/native-mods.md, "Server hooks for … | **CUT** |
| `using_item.rs` | 247 | 11 | An item in use, tick by tick (LivingEntity.startUsingItem, updatingUsingI… | **CORE** |
| `social.rs` | 246 | 4 | SocialInteractionsScreen and PlayerSocialManager on the game side: the pl… | **CUT** |
| `native_reload_listeners.rs` | 245 | 1 | Native mods' own data folders, read on each data load of a server | **CUT** |
| `ominous_item_spawner.rs` | 244 | 2 | OminousItemSpawner: the item an ominous trial spawner drops on its | **CORE** |
| `item_interact_mob_tests.rs` | 243 | 0 | Run alone with private prepared resources: installs process-wide trait mo… | **CUT** |
| `lan_chat.rs` | 243 | 0 | A guest's commands that carry chat: the unsigned and signed command | **CORE** |
| `station_control.rs` | 240 | 0 | Control-socket commands for menus and item components, so scripts can | **CUT** |
| `native_entity_state.rs` | 238 | 0 | An entity's state flags for native server mods, through an EntityRef | **CUT** |
| `falling_damage.rs` | 237 | 2 | Landing impacts for falling blocks, before their placement/drop decision | **CORE** |
| `lan_mount_menu.rs` | 233 | 0 | The horse inventory for a server's players (ServerPlayer.openHorseInvento… | **CORE** |
| `native_mob_draw.rs` | 231 | 0 | Mobs drawn by native mods on the client: native_mob_submit (vanilla's | **CUT** |
| `commands/players.rs` | 230 | 0 | Commands acting on the other players of a hosted world or a server | **GATE** |
| `emotes.rs` | 229 | 1 | Emotes ): short animations of the player | **CUT** |
| `native_criteria.rs` | 229 | 0 | A mod's own advancement criteria triggers (docs/native-mods.md, | **CUT** |
| `native_world_read.rs` | 229 | 0 | Read-only block and tag queries for native server hooks | **CUT** |
| `mob_gear.rs` | 228 | 0 | Enchanting what mobs spawn with (Mob.populateDefaultEquipmentEnchantments | **CORE** |
| `dedicated/status.rs` | 221 | 0 | What horizon-server asks the dedicated server on its control endpoint (--… | **CUT** |
| `sulfur_bucket_tests.rs` | 221 | 0 | SulfurCube.mobInteract's last step, Bucketable.bucketMobPickup: an | **CUT** |
| `ui_control.rs` | 221 | 0 | The widget tree of the open screen for agents (ui, click ID, set ID | **CUT** |
| `native_player_reads.rs` | 220 | 0 | What a server mod reads about a player (docs/native-mods.md, "Server hook… | **CUT** |
| `emote_wheel.rs` | 217 | 2 | The emote wheel (key.emote, B by default; bindable on a controller): the … | **CUT** |
| `composter.rs` | 216 | 2 | ComposterBlock: compostable items go in by hand (useItemOn) or | **CORE** |
| `vibration_tests.rs` | 216 | 0 | Game event regressions for server-side block actions | **CUT** |
| `mob_looting.rs` | 214 | 0 | Mob.aiStep's looting loop: a mob with canPickUpLoot takes what lies | **CORE** |
| `shoulders.rs` | 214 | 0 | Parrots on a player's shoulder: a tame parrot lands on its owner | **CORE** |
| `decorated_pot.rs` | 213 | 1 | Decorated pots, which Horizon keeps as loaded (the chunk's saved block | **CORE** |
| `place_feature_tests.rs` | 208 | 0 | PlaceCommand.placeFeature with an inline feature value | **CUT** |
| `resource_tables.rs` | 206 | 0 | The game's shared read-only tables: Resources (blocks, items, recipes, mo… | **CORE** |
| `native_profiles.rs` | 205 | 0 | Native mods' profile helpers (docs/native-mods.md, "Server hooks for plug… | **CUT** |
| `commands/data/mod_block_entity_tests.rs` | 204 | 0 | Actual command execution with prepared resources | **GATE** |
| `seats.rs` | 204 | 0 | Vehicles with nothing of their own to steer or seat with: armor stands, d… | **CORE** |
| `item_actions.rs` | 203 | 4 | A click that uses the held item at nothing or at an entity (Minecraft.sta… | **CORE** |
| `native_client_particles_fixture.rs` | 203 | 0 | Headless proof of the generated Host bridge and the ordinary particle que… | **CUT** |
| `world_test_def_tests.rs` | 202 | 0 | Test instances come from the data packs the world enables | **CUT** |
| `campfire.rs` | 201 | 2 | Campfires' cooking: CampfireBlock.useItemOn (CampfireBlockEntity.placeFoo… | **CORE** |
| `command_minecarts.rs` | 195 | 0 | MinecartCommandBlock: its BaseCommandBlock run by a powered activator | **CORE** |
| `pickups.rs` | 195 | 3 | ItemPickupParticle: a taken item entity, experience orb, arrow or trident… | **CORE** |
| `melee.rs` | 194 | 5 | A player's melee attack (Player.attack): the attack strength, critical an… | **CORE** |
| `pad/hardware/triggers.rs` | 194 | 0 | Read triggers from mapped buttons, or the conventional unmapped Linux axes | **CUT** |
| `screen_info.rs` | 194 | 0 | What the in-game screens narrate where vanilla's override | **CORE** |
| `native_living_refs.rs` | 193 | 0 | Living entities for native server mods, through a LivingRef | **CUT** |
| `commands/raid.rs` | 192 | 0 | RaidCommand: /raid start/stop/check/spawnleader/setomen/glow/sound | **GATE** |
| `native_packets.rs` | 192 | 0 | Packets, plugin channels, resource packs and kicks for server mods (docs/… | **CUT** |
| `prediction.rs` | 191 | 0 | The movement prediction's replay on the server (lan::prediction): each gu… | **CORE** |
| `pandas.rs` | 190 | 0 | Pandas on the game side: the food they find on the ground and pick up | **CORE** |
| `foxes.rs` | 189 | 0 | Foxes and dolphins on the game side: what they take from the ground (Fox.… | **CORE** |
| `split/setup.rs` | 189 | 0 | P1's Setup screen's side in the game: the arrangement as a draft, and App… | **CUT** |
| `storage_alias_tests.rs` | 188 | 0 | /data modify storage … value set value "bad": StorageDataAccessor | **CUT** |
| `test_block_edit.rs` | 187 | 0 | TestBlockEditScreen: the test block's mode and message | **CORE** |
| `lan/event_timings.rs` | 185 | 0 | Attribution for slow steps made of many short events: each event under th… | **CORE** |
| `chiseled_bookshelf.rs` | 184 | 1 | Chiseled bookshelves: ChiseledBookShelfBlock.useItemOn / useWithoutItem | **CORE** |
| `enderman_placement_tests.rs` | 184 | 0 | Exercise the actual registered leave-block goal and Game event handler | **CUT** |
| `native_host_bridge.rs` | 183 | 0 | Host forms of documented Game helpers that dyn Host could not carry: | **CUT** |
| `blockctl.rs` | 181 | 0 | Control-socket block commands for scripted tests: setblock, fill, | **CUT** |
| `memory.rs` | 180 | 0 | horizon-ctl memory: what holds the game's memory, by category | **CUT** |
| `native_entity_moves.rs` | 179 | 0 | Moving and turning an entity for native server mods, through an | **CUT** |
| `screen_backgrounds.rs` | 178 | 11 | What a frame draws behind the screens: the title panorama, the level load… | **CORE** |
| `lan_quiet.rs` | 177 | 0 | Quiet commands (horizon_protocol::quiet): a Horizon client's mod sends a | **CORE** |
| `world_primitives.rs` | 177 | 1 | Native mods' world primitives (native_world_primitives): asked once a fra… | **CORE** |
| `debug_stick.rs` | 172 | 2 | DebugStickItem: selecting a block-state property with the left button and | **GATE** |
| `enderman_hurt_teleport_tests.rs` | 172 | 0 | Enderman.hurtServer teleports inside the hurt the game layer deals | **CUT** |
| `moving_pistons.rs` | 172 | 2 | PistonHeadRenderer: while a piston moves them, blocks are | **CORE** |
| `falling_damage/helmet_tests.rs` | 171 | 0 |  | **CUT** |
| `no_resources.rs` | 171 | 0 | A game started without its prepared files (the game build run by hand, not | **CUT** |
| `split/hud.rs` | 171 | 1 | What splitscreen draws over a player's view: its badge, questions answere… | **CUT** |
| `native_ticks.rs` | 170 | 3 | Entities ticking for native mods (native_entity_tick_pre, native_entity_t… | **CUT** |
| `mod_browser.rs` | 168 | 0 | Options > Mods > Browse mods : reading the | **CUT** |
| `llamas.rs` | 166 | 0 | Llamas on the game side: AbstractChestedHorse.mobInteract and | **CORE** |
| `maps/live_frame_tests.rs` | 166 | 0 |  | **CUT** |
| `nautili.rs` | 166 | 0 | Nautili on the game side (AbstractNautilus.mobInteract): taming with | **CORE** |
| `native_entity_motion.rs` | 163 | 0 | An entity's motion and shape for native server mods, through an | **CUT** |
| `transient_blocks.rs` | 162 | 2 | ClientboundAddTransientBlockPacket: a block the server places that the | **CORE** |
| `maps/save_tests.rs` | 159 | 0 |  | **CUT** |
| `remote_camera.rs` | 159 | 4 | A server's spectator camera (ClientPacketListener.handleSetCamera, | **CORE** |
| `clone_block_ticks_tests.rs` | 157 | 0 | CloneCommands.clone ends with LevelTicks.copyAreaFrom: every block | **CUT** |
| `native_player_fx.rs` | 157 | 0 | What server mods send one player (docs/native-mods.md, "Server hooks for | **CUT** |
| `net_harness.rs` | 157 | 0 | Headless multiplayer client for tools/test_dedicated_server_parity.py: | **CUT** |
| `remote_stations.rs` | 157 | 0 | A server's workstation menus on this client: the server opens the menu | **CORE** |
| `scoreboard/guest_advancement_tests.rs` | 157 | 0 |  | **CUT** |
| `mob_discard_tests.rs` | 156 | 0 | Actual entity removal, commands and chunk-save assembly, with no interven… | **CUT** |
| `test_blocks.rs` | 156 | 3 | Test blocks on the server: handleSetTestBlock and the mode a placed | **GATE** |
| `ime.rs` | 155 | 5 | Input method (IME) text: committed composition goes to the focused text | **CORE** |
| `lan_idle.rs` | 155 | 0 | Idle mobs and items that need no new description this tick (#10253) | **CORE** |
| `mob_sounds.rs` | 155 | 0 | The looping sound instances of mobs: a bee's buzz | **CORE** |
| `pad/hardware/face_buttons.rs` | 155 | 0 | Linux's codes for X and Y don't say where those buttons sit | **CUT** |
| `beds.rs` | 151 | 4 | Beds' occupied (BedBlock.OCCUPIED): the head of a bed someone sleeps | **CORE** |
| `boat_authority_fixture.rs` | 150 | 0 | The native parity harness runs the client boat ticker and authoritative | **CUT** |
| `attachment_sync.rs` | 149 | 0 | Attachment sync : the server | **CORE** |
| `native_chunk_snapshot.rs` | 149 | 0 | Read-only chunk snapshots for native server mods (docs/native-mods.md, | **CUT** |
| `keymap_tests.rs` | 147 | 0 | KeyEvent has private platform fields | **CUT** |
| `render_control.rs` | 145 | 0 | Control-socket commands for inspecting rendering: place blocks without | **CUT** |
| `test_entities.rs` | 145 | 0 | What the game tests do to the entities and chunks of a test's area: | **CORE** |
| `jigsaw_blocks.rs` | 142 | 1 | Jigsaw blocks on the server: handleSetJigsawBlock and | **GATE** |
| `mining_component_tests.rs` | 142 | 0 |  | **CUT** |
| `clipboard.rs` | 140 | 15 | Copy and paste in the text fields: KeyboardHandler's clipboard and the | **CORE** |
| `cat_spawner.rs` | 139 | 0 | CatSpawner: every 1200 ticks a cat may appear near a random player, | **CORE** |
| `native_explosions.rs` | 139 | 0 | Explosions for native server mods : a mod | **CUT** |
| `bundles.rs` | 137 | 3 | BundleMouseActions: the wheel over a bundle in a container screen selects | **CORE** |
| `zombie_reinforcements.rs` | 136 | 0 | Zombie.hurtServer's reinforcements: a hurt zombie on Hard may call | **CORE** |
| `native_falling.rs` | 134 | 0 | Falling blocks for native server mods (docs/native-mods.md, "Falling | **CUT** |
| `interactions.rs` | 133 | 0 | Server minecraft:interaction entities (Interaction): invisible boxes a | **CORE** |
| `win.rs` | 133 | 3 | WinScreen in the game: the poem and credits after leaving the End for | **CORE** |
| `tick_script.rs` | 132 | 1 | HORIZON_TICK_SCRIPT=PATH (tools/test_wire_stream_parity.py): a server's c… | **CUT** |
| `item_particles.rs` | 131 | 0 | The sprites of item particles: BreakingItemParticle.ItemParticleProvider.… | **CORE** |
| `key_codes.rs` | 131 | 0 | Key and button codes as GLFW and vanilla's InputConstants number them, an… | **CORE** |
| `pick_entity.rs` | 131 | 0 | Pick Block on an entity (Minecraft.pickBlockOrEntity's entity case and | **CORE** |
| `item_contact_tests.rs` | 130 | 0 |  | **CUT** |
| `locator_bar.rs` | 128 | 2 | The locator bar on this client (horizon_client::locator_bar): the | **CORE** |
| `remote_mob_particles.rs` | 127 | 0 | Particles a client of a server draws for a mob's entity event, which the | **CORE** |
| `split/launcher.rs` | 127 | 0 | Microsoft sessions handed over by the launcher; offline split profiles be… | **CUT** |
| `chat/suggestion_completion_tests.rs` | 125 | 0 | Exercise the actual Game keyboard/mouse handlers and generated mod dispat… | **CUT** |
| `growth.rs` | 125 | 2 | Client glue for sapling growth and bone meal: installs the live feature | **CORE** |
| `saves_control.rs` | 125 | 0 | Worlds and the multiplayer server list from the control socket: what the … | **CUT** |
| `player_spawn.rs` | 124 | 1 | Placing the local player in a world it opened: at its saved position once… | **CORE** |
| `enderman.rs` | 123 | 1 | Enderman leave-block attempts need the authoritative block simulation | **CORE** |
| `interaction_shapes.rs` | 123 | 0 | BlockBehaviour.getInteractionShape of the four blocks that override it in | **CORE** |
| `block_particles.rs` | 121 | 4 | Block particles: the sprite and tint of a block's faces and particle mate… | **CORE** |
| `dynamic_lights.rs` | 120 | 1 | Horizon Extras' dynamic lights (horizon_client::dynamic_light): the light… | **GATE** |
| `native_chunk_tickets.rs` | 120 | 0 | Chunks a native mod keeps loaded (NeoForge's TicketController): a train | **CUT** |
| `powder_snow.rs` | 119 | 3 | Powder snow around the player: its snowflakes, fire put out by it, and the | **CORE** |
| `native_entity_data.rs` | 118 | 0 | An entity's saved data, tags and name for native server mods, through an | **CUT** |
| `render_settings.rs` | 117 | 6 | The renderer and its settings: building it for the window, applying the v… | **CORE** |
| `spectator.rs` | 116 | 0 | The spectator menu (SpectatorGui): its players and teams from the | **CORE** |
| `ominous_item_spawner/warning_tests.rs` | 113 | 0 |  | **CUT** |
| `raids/tests/bed_loss.rs` | 110 | 0 | Real Game raid creation/wave dispatch with a loaded claimed-bed precondit… | **CORE** |
| `titles.rs` | 109 | 2 | Titles, the action bar and the selected item name: the state and layout | **CORE** |
| `pad/hardware/sdl_row.rs` | 108 | 0 | What gilrs drops when it reads an SDL row: ~, which says an axis runs the… | **CUT** |
| `boats/placement.rs` | 107 | 0 | BoatItem's server POV clip; deliberately separate from renderer/mining pi… | **CORE** |
| `entity_sounds.rs` | 107 | 0 | The entity overload of level sounds, shared by mob and player call sites | **CORE** |
| `sniffers.rs` | 107 | 1 | Sniffers on the game side: the egg a bred pair lays | **CORE** |
| `scoreboard/criterion_tests.rs` | 106 | 0 |  | **CUT** |
| `commands/data/saved_tag_tests.rs` | 105 | 0 |  | **GATE** |
| `scoreboard/empty_tag_tests.rs` | 105 | 0 |  | **CUT** |
| `cauldrons.rs` | 102 | 1 | Using an item on a cauldron (CauldronInteraction): what the click does, a… | **CORE** |
| `native_level_refs.rs` | 101 | 0 | A level's blocks and time for native server mods, through a LevelRef | **CUT** |
| `atlas_slots.rs` | 100 | 0 | The GUI atlas's fixed slots for runtime images (horizon/skin{N}, | **CORE** |
| `creative_hotbar.rs` | 100 | 0 | The creative toolbars, hotbar.nbt beside options.txt: hold the save or | **CORE** |
| `headless.rs` | 99 | 0 | --headless (#4951): a client with no display, no window and no renderer | **CUT** |
| `lan_waypoints.rs` | 99 | 0 | The locator bar of the players on a served world (lan/waypoints.rs): what | **CORE** |
| `autosave.rs` | 98 | 4 | The world's save on a timer (MinecraftServer.computeNextAutosaveInterval, | **CORE** |
| `entity_culling_tests.rs` | 98 | 0 | Entity.setViewScale: the entity distance option times the render | **CUT** |
| `native_fluid_render.rs` | 96 | 0 | Still-fluid geometry under the native block entity pose, with an ordinary… | **CUT** |
| `player_equip.rs` | 96 | 5 | LivingEntity.onEquipItem for players: the equip sound and the equip | **CORE** |
| `pumpkin.rs` | 96 | 1 | PumpkinBlock.useItemOn: shears carve a pumpkin into a carved pumpkin | **CORE** |
| `native_permissions.rs` | 94 | 0 | Permission nodes for native mods (docs/native-mods.md, "Server hooks for | **CUT** |
| `commands/admin.rs` | 93 | 0 | Which command feedback vanilla tells the other operators and the console | **GATE** |
| `native_components.rs` | 93 | 0 | Native item data component helpers | **CUT** |
| `campfire_douse.rs` | 92 | 1 | CampfireBlock.useItemOn: an item in #minecraft:douses_campfires (the | **CORE** |
| `gamemode_switcher.rs` | 92 | 1 | The non-pausing F3+F4 screen (GameModeSwitcherScreen) | **CUT** |
| `boat_rider_fixture.rs` | 91 | 0 | Headless passenger-order regression through the real remote client paths | **CUT** |
| `mob_index.rs` | 91 | 0 | Finding a mob by its network id without walking the whole list: a | **CORE** |
| `native_block_sprites.rs` | 88 | 0 | Where blocks' textures are in the block sprite arrays, for a client mod d… | **CUT** |
| `native_level_effects.rs` | 88 | 0 | Sounds and particles in a level for native server mods, through a | **CUT** |
| `pad/hardware/hid_layout.rs` | 88 | 0 | A pad the kernel's generic HID driver describes, which an SDL row would o… | **CUT** |
| `dedicated/events.rs` | 87 | 0 | What happened on the dedicated server, typed, for horizon-server's event … | **CUT** |
| `native_damage.rs` | 86 | 0 | Who a hit names, for native_living_incoming_damage_v3 (docs/native-mods.m… | **CUT** |
| `native_mounts.rs` | 86 | 0 | Mounting for native mods (native_entity_mount: NeoForge's EntityMountEven… | **CUT** |
| `packs/folder.rs` | 85 | 0 | Resolve paths in the game's filesystem context before handing them to a | **CORE** |
| `native_client_particles.rs` | 84 | 0 | Local particle requests from native client hooks | **CUT** |
| `legacy_rules.rs` | 82 | 3 | Legacy combat rules on the worlds this game serves (horizon_client::legac… | **CORE** |
| `native_motion.rs` | 82 | 0 | The player's motion for mods : a push for the local player, on a | **CUT** |
| `commands/selector_bounds.rs` | 81 | 0 | The physical bounds already kept for selector targets | **GATE** |
| `skin_models.rs` | 81 | 0 | The cache behind the threeDSkinLayers option: one extruded model per | **CORE** |
| `lan_far.rs` | 80 | 0 | Far terrain for a server's Horizon clients (horizon_client::lod_net): a | **CORE** |
| `custom_sky.rs` | 76 | 1 | OptiFine custom skies (horizon_client::custom_sky): each frame, the layer… | **GATE** |
| `portal_ticking_tests.rs` | 73 | 0 | Entity.handlePortal runs in the entity's own tick, and ServerLevel.tick | **CUT** |
| `native_world_columns.rs` | 72 | 0 | Column reads for server mods, as helpers on the level being ticked: many … | **CUT** |
| `boarding.rs` | 71 | 0 | A player's Entity.boardingCooldown is always 0: Player.removeVehicle | **CORE** |
| `entity_inside_tests.rs` | 70 | 0 | Entity.applyEffectsFromBlocks runs in the entity's own tick, and | **CUT** |
| `glowing.rs` | 70 | 0 | Glowing entities (EntityRenderer.extractRenderState's outlineColor): whic… | **CORE** |
| `creatures/pufferfish_player.rs` | 69 | 0 | Pufferfish.playerTouch in the real player's tick, independent of fish AI | **CORE** |
| `native_level_world.rs` | 69 | 0 | A level's world settings for native server mods, through a LevelRef | **CUT** |
| `banners.rs` | 68 | 1 | Placed banners (BannerBlockEntity): the pattern layers move from the | **CORE** |
| `breezes.rs` | 68 | 0 | Breeze particles (Breeze.tick): block dust at its feet while it stands, | **CORE** |
| `native_world_edit.rs` | 67 | 0 | Bulk block edits for server mods: a helper on the level being ticked, as … | **CUT** |
| `postprocess.rs` | 67 | 1 | LevelChunk.postProcessGeneration: positions that worldgen marked for | **CORE** |
| `random_textures.rs` | 67 | 0 | OptiFine random entity textures: each mob's variants, chosen when this wi… | **CORE** |
| `event_loop.rs` | 65 | 0 | What the game asks of the loop that runs it | **CORE** |
| `subtitle_hud.rs` | 59 | 1 | The subtitle overlay in the game (Hud -> SubtitleOverlay): the sound | **CORE** |
| `structures.rs` | 55 | 0 | Which structures contain a position (StructureManager.getStructureAt | **CORE** |
| `quick_actions.rs` | 51 | 0 | The Quick Actions dialog (key.quickActions, default G), read the way | **CORE** |
| `native_view_distance.rs` | 49 | 0 | One player's view distance for native server mods (docs/native-mods.md, | **CUT** |
| `discord.rs` | 48 | 1 | What the player is doing, for Discord Rich Presence (horizon_client::disc… | **CUT** |
| `split/frames.rs` | 45 | 0 | The frame-time readout (HORIZON_SPLIT_STATS=1, docs/extras.md) | **CUT** |
| `native_biome_colors.rs` | 42 | 0 | Biome colours a client mod changes (native_biome_colors), for seasons: | **CUT** |
| `native_terrain_model.rs` | 42 | 0 | Explicit terrain-sheet material/shading/UV policy for a native standalone… | **CUT** |
| `friends_off.rs` | 33 | 3 | Play with Friends left out of the build (the friends feature off, as in t… | **CUT** |
| `sheep_dye.rs` | 29 | 0 | Whether interact_sheep_dye would act on a client, on a copy of the sheep | **CORE** |
| `execution_role.rs` | 25 | 0 | A Game's execution role is fixed at construction | **CORE** |
| `native_menu_stacks.rs` | 25 | 0 | The stacks of a server-opened menu for native client mods | **CUT** |
| `native_world_border.rs` | 25 | 0 | The world border for native server mods (docs/native-mods.md, "Server | **CUT** |
| `native_world_seed.rs` | 17 | 0 | The world seed for native server mods (docs/native-mods.md, "Server hooks | **CUT** |
