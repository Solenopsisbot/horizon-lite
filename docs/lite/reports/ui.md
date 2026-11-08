# Horizon Lite: UI, input, audio, accessibility, cosmetics

Scope: `crates/horizon-client/src` (gameplay + `game/`), `crates/horizon-client-lib` sources under the same
tree, `crates/horizon-client-render`, `crates/horizon-client-input`, `crates/horizon-narrator`,
`crates/horizon-cosmetics`, plus the `horizon-friends`/`horizon-chat-filter`/`horizon-anticheat` crates
where they touch this slice. Read-only survey; no cargo build was run.

Method: `wc -l` totals (tests included; that inflates title/options/pad by 30–50 %), module docs,
`grep` of call sites, and `docs/forking.md`/`docs/extras.md`/`docs/controllers.md`/`docs/narrator.md`
which already define the intended gates. Figures are line counts, not effort.

## Headline findings

1. **`horizon-extras` is a behaviour gate, not a compile gate.** There are exactly 4 compile-time
   `cfg!(feature = "horizon-extras")` sites, in 3 files (`game.rs`, `entry.rs`, `game/cosmetics.rs`),
   plus one runtime bool (`options_ui::HORIZON_EXTRAS`, set in `entry.rs:16-20` and read in
   `options_ui.rs:24-29`). A `--no-default-features --features audio` build still compiles every
   Realms, multiplayer, cosmetics, PvP, splitscreen and Horizon-settings file. The gate only hides the
   Settings/Mods buttons (`options_ui.rs:3140-3155`) and short-circuits
   `game::cosmetics::enabled()` (`game/cosmetics.rs:436-440`). Do not treat it as "Horizon Lite mode".
2. **The largest removable mass in this slice is not the screens, it is the Horizon-specific option
   surface** (~10 k) and the platform features bolted around it: Realms (8.6 k), cosmetics/emotes
   (8.3 k), controllers (14.8 k incl. DualSense), splitscreen (6.8 k), PvP/extras (6.8 k), Friends (5.3 k).
3. **Audio is already cleanly feature-gated.** `audio.rs` has 1,233 lines behind
   `#[cfg(feature = "audio")]` and 11-line stubs otherwise; `sound_engine` (2,105) is deliberately
   *not* gated because subtitles and `horizon-ctl` read the same `heard`/notification stream. Dropping
   the feature saves ~1.2 k + cpal, not the 7.4 k audio subsystem.
4. **Controllers are Horizon-only** (vanilla 26.3 has no gamepad input at all). But the `controllers`
   Cargo feature only swaps `pad/hardware.rs` for a stub; ~11.8 k of pad menus/binds/guide/OSK compile
   regardless. Dropping support for real means deleting `game/pad*.rs` and rewiring ~90 external call sites.
5. **Splitscreen is the application wrapper**, not a screen: `App::Ready(Box<split::Split>)`
   (`game/loading_screen.rs:389-392`, constructed at line 32). Cutting it is a startup rewrite, not a
   file delete.

## 1. Inventory and verdicts

Verdicts: **CORE** keep, **CUT** delete, **GATE** keep behind an off-by-default feature, **REWRITE**
replace with a smaller implementation. LOC is total including tests.

### 1a. Screens and menus

| Subsystem | Files | LOC | Verdict | What the player loses | Risk | Edit points |
|---|---|---:|---|---|---|---|
| Title + world select/create/edit/repair | `title.rs` 5,114; `title/` 5,964 (2,626 tests); `startup_menu.rs` 1,510; `loading_screen.rs` 528; `screen_backgrounds.rs` 177; render `title_edition.rs` 490 | 13,783 | **REWRITE** (prune) | Realms/Multiplayer/Friends entry points, Superflat/Buffet/experiments editors if cut; brand strings | Medium | `title.rs:270-370` `Mode`, `:371-404` `Action`, `:1803-1860` main buttons; `title/` submodules; `game/loading_screen.rs:32,389` |
| Options dispatcher (vanilla pages) | render `options_ui.rs` 8,402; `options_file.rs` 888; `settings.rs` 1,192; `options_fixes.rs` 324 | 10,806 | **REWRITE** | Horizon Settings/Mods/Graphics/Controller/Extras/PvP/Studio/Split/Music pages; vanilla pages stay | High: one 8 k match-heavy file | `options_ui.rs:1314-1370` `Page`, `:3097-3155` Main entries, `:2660` row builder |
| Horizon graphics options | `graphics_ui.rs` 3,466; `graphics_style.rs` 375; `shader_ui.rs` 1,332; `shader_pack_list.rs` 665; `shader_options.rs` 343 | 6,181 | **CUT** | Advanced video page (HDR, upscaling, frame gen, culling), shader-pack UI | Medium | `options_ui.rs:2381-2387`; `Page::Video` is dead code already (`options_ui.rs:2804-2806`) — restore it as the lite Video page |
| Horizon settings shell | `settings_shell.rs` 2,127; `controller_ui.rs` 1,564; `extras_ui.rs` 268 | 3,959 | **CUT** | The whole list/dock/search settings frame and Controller page | Low (only Horizon pages use it) | `options_ui.rs:2243-2260,2356-2371` |
| Multiplayer / Realms | `multiplayer.rs` 3,008; `realms.rs` 6,098 + `realms/` 2,511; `social_screen.rs` 520; `game/server_links.rs` 595; `game/social.rs` 245 | 12,977 | **CUT** | Server list, add/edit/direct connect, LAN discovery/join, Realms, social interactions, server links | Medium (title + net integration) | `title.rs:338-340,3578-3632`; `Title::Mode::Multiplayer/Realms`; `game.rs:15861` friends click |
| Play with Friends | `friends_screen.rs` 340; `game/friends.rs` 334; `horizon-friends` 4,675 | 5,349 | **CUT** | Invite-code sharing/joining | Low (already behind `friends`) | `game.rs:157-162`; `net.rs:492-519`; `Screen::Friends` |
| Splitscreen | `game/split.rs` 928 + `game/split/` 2,502; render `split_ui.rs` 1,664, `split_layout.rs` 758, `split_map.rs` 166, `split_profiles.rs` 734 | 6,752 | **CUT/REWRITE** | Local co-op, second windows, controller seat routing | High: app wrapper, window/frame pacing | `loading_screen.rs:32,389`; `game.rs:613-620,2534-2542`; `game/split/windows.rs:51` |
| Extras, PvP, minimap, HUD editor | render `extras.rs` 1,257, `extras_ui.rs` 268, `pvp.rs` 1,835, `pvp_hud.rs` 792, `minimap.rs` 682; game `game/extras.rs` 283, `game/tweaks.rs` 545, `game/pvp.rs` 764, `game/hud_editor.rs` 255, `extras_hud.rs` 143 | 6,824 | **CUT** | Fullbright, dynamic lights, minimap, auto-reconnect, inventory tweaks/sort, custom crosshair/HUD widgets, zoom hooks | Medium (~100 `self.settings.extras` refs in `game.rs`) | `game.rs:7878,7973,12751,14401,16380`; `Page::Extras/Pvp`; `options_ui.rs:1816-1846` |
| Cosmetics and emotes | `horizon-cosmetics` 6,343; `game/cosmetics.rs` 1,180, `cosmetics/fx.rs` 321, `game/emotes.rs` 228, `game/emote_wheel.rs` 216 | 8,288 | **CUT** | Cosmetic items, emote animations, emote wheel, "Horizon player" mark/presence | Medium (155 refs in 13 gameplay files, incl. mob pose and name tags) | `game/cosmetics.rs:436`; `game.rs:131-132,958,2956`; `tab_list.rs:347,614`; `mobs/anim.rs` |
| HUD core | render `hud.rs` 4,597, `hud_layout.rs` 940, `hud_overlays.rs` 1,383; game `hotbar.rs` 141, `hunger.rs` 200, `boss_overlay.rs` 243, `locator_bar.rs` 742, `subtitle_hud.rs` 58 | 8,304 | **CORE** | — | Low | — |
| Widgets/text/draw | render `ui.rs` 2,432, `screen_draw.rs` 1,429, `widgets.rs` 1,471, `font.rs` 1,881, `menu_blur.rs` 474, `screen_effects.rs` 439 | 8,126 | **CORE** | — | Low (but see registration trap) | `ui.rs:535`; `screen_draw.rs:554`; `graphics_style.rs:191` |
| Chat + command entry | render `chat.rs` 2,136; game `game/chat.rs` 2,694 | 4,830 | **CORE** | — | Low (drop `horizon.chat.timestamp/repeats/search` keys if desired) | `options_ui.rs:285` |
| Tab list | `tab_list.rs` 870 | 870 | **CORE** | Player list (SP: yourself) | Low | `tab_list.rs:347,543-620` (Horizon mark) |
| Pause / death | `game/screens.rs` 978 | 978 | **CORE** | — | Low | `:67-119` `pause_buttons`, `:159` split row |
| Containers/books/signs/trading/creative | `container_screen.rs` 384, `merchant.rs` 1,291, `books.rs` 1,591, `sign_edit.rs` 908, `creative_screen.rs` 452, `recipe_book_screen.rs` 734, plus `menu.rs` 4,356 (menu logic) | 9,716 | **CORE** | — | Low | — |
| Resource-pack screen | `pack_screen.rs` 1,968 | 1,968 | **CORE/REWRITE** | Built-in Modrinth search/download (~500 LOC) if cut | Low | `pack_screen.rs:323-347,1128-1335` |
| Debug (F3, F3+F6) | `debug_overlay.rs` 826, `game/debug_keys.rs` 1,427, `game/debug_options.rs` 614, `game/debug_lines.rs` 581, `debug_chart.rs` 644, `debug_entries.rs` 509, `perf_overlay.rs` 110 | 4,711 | **CORE** | — (F3 is vanilla; keep) | Low | `game/debug_options.rs:517` exhaustive `Screen` match |
| Studio / agent | `game/studio.rs` 950, render `studio_ui.rs` 566, `game/agent.rs` 2,264, `game/ui_control.rs` 220, `game/events.rs` 362, `game/repro.rs` 1,972, `screenshot_sequence.rs` 317 | 6,651 | **CUT** | Recordings/replays, Replay Studio, AI agent control/recording, scripted screenshots | Medium (control API, tests; agent control is *not* behind `horizon-extras`) | `Page::Studio/Agent`; `game.rs:3110-3119,7963`; `control.rs`. Keep `ui_control.rs` if `horizon-ctl ui`/`click` stays. |
| Chat filter / anticheat | `game/chat_filter.rs` 537; `horizon-chat-filter` 1,171; `horizon-anticheat` 1,052 | 2,760 | **CUT** (server slice) | Dedicated-server moderation only; **no client UI** | Low | `game/chat_filter.rs`; `lan/anticheat.rs`; `server.toml` |

### 1b. Options surface: Horizon vs vanilla

| Surface | Where | LOC | Verdict |
|---|---|---:|---|
| Vanilla pages: Main, Video, Sound, Controls, Key Binds, Mouse, Chat, Accessibility, Language, Font, Packs, Skin, Online, Credits | `options_ui.rs` | ~5.3 k production incl. shared engine (plus ~3.1 k tests) | **CORE** |
| Horizon Settings hub and pages: Extras, PvP & HUD, Splitscreen, Studio, AI Agent, Discord | `options_ui.rs` (`Page::Horizon`), `extras_ui.rs`, `pvp.rs`, `extras.rs` | ~2.3 k in dispatcher + 6.8 k extras | **CUT** |
| Graphics (General/Quality/Performance/Shaders/Advanced/HDR) replacing Video Settings | `graphics_ui.rs`, `shader_ui.rs`, `shader_pack_list.rs`, `shader_options.rs`, `graphics_style.rs` (+ `settings_shell.rs` 2.1 k shared with the other Horizon pages) | ~6.2 k (+2.1 k shell) | **CUT** |
| Controller settings / binds | `controller_ui.rs` | 1,564 | **GATE/CUT** |
| Mods / Mod browser / native mod settings | `options_ui.rs` `Page::Mods/ModBrowser/ModProject/NativeMod`, `mod_list.rs`, `mod_browser` | ~2 k in options + mod runtime | **CUT/GATE** |
| Music page | `options_ui.rs`, `game/music.rs` | ~0.8 k | **CUT** (keep music playback) |
| 3D skin layers, chat delay, controller options (`horizon.options.*`) | `options_ui.rs` `Opt` | ~0.5 k | **CUT** |

Vanilla option state lives in `settings.rs`/`options_file.rs`; Horizon's own files are separate
(`horizon-graphics.txt`, `horizon-controller.txt`, `horizon-extras.txt`, `horizon-mods.txt`), which is
good: deleting the pages does not corrupt `options.txt`.

### 1c. Input / controllers

| Part | LOC | Verdict | Notes |
|---|---:|---|---|
| `horizon-client-input` core: keybinds 653, keymapping 308, mouse 568, window 1,000, clipboard 493, keys/actions/held/snap/input ~1.1 k | ~5.3 k | **CORE** | Key bind persistence, mouse options, winit window helpers. |
| `gamepad.rs` 2,541 + `gameplay_guide.rs` 962 | 3,503 | **GATE** | Pure mapping/settings/glyph names; always compiled. |
| `game/pad*.rs`: pad 851, pad_menu 2,722, pad_craft 912, pad_actions 303, guide 652, hardware 843 (+ hardware/* 541), parity tests 268 | 7,092 | **GATE** | Only `pad/hardware.rs` is behind `controllers` (`game/pad.rs:101`, stub at `:134`). |
| `controller_ui.rs` 1,564, `controller_notice.rs` 230, `pad_glyph.rs` 386, `osk.rs` 421 | 2,601 | **GATE** | OSK and glyph art are Horizon-only. |
| `horizon-dualsense` 1,621; gilrs/cpal deps | — | **GATE** | DualSense output. |
| Total controller surface | ~14.8 k (+619 `split/pads.rs`) | **GATE** | ~821 `pad`/`.pad` references, but 514 are inside `pad_menu.rs`; external call sites ~90–120. |

Dropping the `controllers` feature alone: removes gilrs/libudev and `horizon-dualsense` linkage, keeps
~11.8 k of pad UI compiled. Deleting support for real: ~13.2 k out (+1.6 k DualSense), plus edits in `game.rs`,
`window_handler.rs`, `screens.rs`, `title.rs`, `multiplayer.rs`, `options_ui.rs`, `settings.rs`,
`split/*`, and the control tool's virtual pad. That is the single riskiest deletion in this slice.
Steam Deck players lose the whole input mode.

### 1d. Audio

| Part | LOC | Feature-gated? | Verdict | Notes |
|---|---:|---|---|---|
| `audio.rs` (mixer, cpal, device probe) | 2,522 | 1,233 lines `#[cfg(feature="audio")]`, 11 stub lines | **CORE/GATE** | Without it: silent game, but no crash; `output_devices()` returns empty. |
| `sound_engine.rs` (channels, categories, subtitles notifications) | 2,105 | **No** | **CORE** | Needed for subtitles, `horizon-ctl` `heard`, network sound capture. |
| `sound_events.rs` (sounds.json, weighted variants) | 553 | No | **CORE** | |
| `sound_preview.rs` (volume sliders) | 180 | No | **CORE** (or cut with Sound page preview) | |
| `music.rs` 1,099 + `game/music.rs` 416; `ambience.rs` 484 | 1,999 | No (logic), depends on `Audio` | **CORE** | Vanilla music/ambience. |
| `subtitle_hud.rs` + `hud_overlays` subtitle section | 58 + ~300 | No | **CORE** (accessibility) | Works with no audio device: notifications still arrive. |

Minimum viable audio = `audio` feature + `audio.rs` + `sound_engine` + `sound_events` + `music` +
`ambience` ≈ 6.2 k. Cutting music/ambience saves 2 k but removes a visible vanilla feature. Do not cut
`sound_engine` with the device layer.

### 1e. Narrator / accessibility

| Part | LOC | Verdict | Notes |
|---|---:|---|---|
| `horizon-narrator` crate (TTS backends: SAPI, NSSpeechSynthesizer, flite) | 1,475 | **GATE** | Vanilla feature (`docs/narrator.md`), no feature gate today. |
| `screen_narrator.rs` (screen narration state, input types) | 1,530 | **GATE** | Used by every screen through `widgets::begin_screen`/`Narratable`. |
| `game/narrator.rs` (tick, key, chat/system speech) | 344 | **GATE** | |
| `game/screen_info.rs` (per-screen narration text) | 193 | **GATE** | |
| High contrast, subtitles, text backgrounds, FOV effects | in `settings.rs`, `hud*`, `options_ui.rs` | part of core | **CORE** | Vanilla accessibility; cheap. |

Narrator is vanilla, not branding; recommend **GATE** rather than CUT. Gating is not a one-line
`cfg`: options cycle (`options_ui.rs:703`), Ctrl+B, chat narration, every screen's narration closure,
and `is_active()`/`Status`/`say_system_now` need stubs. ~3.5 k moves behind a feature for maybe 300 LOC
of stubs.

### 1f. Cosmetics / brand

| Item | LOC | Verdict |
|---|---:|---|
| `horizon-cosmetics` crate | 6,343 | **CUT** |
| Game integration (`cosmetics.rs`, `fx.rs`, `emotes.rs`, `emote_wheel.rs`) | 1,945 | **CUT** |
| "Horizon player" mark in tab list + presence | ~40 + service | **CUT** |
| Title brand: "Horizon {version} (Rust)", nightly label, "not affiliated" notice, `RUST EDITION` banner, window title/app id | ~150 + `title_edition.rs` 490 | **CUT/rename** |
| Official/partner servers seeded into `servers.dat` | ~20 | **CUT** |
| Discord presence 623 + heartbeat 74 | 697 | **CUT** |
| Wardrobe / Shop | **not in the game** — launcher only (`docs/forking.md`) | n/a |

Cosmetics are `ON_BY_DEFAULT = true` in the official build (`horizon-cosmetics/src/lib.rs:43`), so a
lite fork must actually remove/gate them, not rely on the default.

### 1g. Splitscreen and macOS

| Part | LOC | Notes |
|---|---:|---|
| `game/split.rs` + `game/split/{frames,hud,launcher,pads,players,setup,windows}.rs` | 3,430 | `Split` owns `ApplicationHandler`, frame pacing, pad router, window list, auth sessions. |
| `split_ui.rs` 1,664, `split_layout.rs` 758, `split_map.rs` 166, `split_profiles.rs` 734 | 3,322 | Setup screen, monitor map, layout math, profiles. |
| macOS window code | inside `split/windows.rs` (681) | `above_menu_bar` (`:51`) uses `objc2-app-kit`; only split needs it, but `objc2` is also used by narrator's `NSSpeechSynthesizer`. |

## 2. Minimum UI for Lite

Definition (the requested minimum): title screen with **Singleplayer / Options / Quit** (+ Language and
Accessibility icons, which are vanilla and nearly free), world select, create world, pause menu, options
(Video, Controls/Key Binds, Sound), and the in-game HUD. Not included: multiplayer, Realms, chat,
inventory/containers, pack browser, stats, advancements, debug.

Recommended shape:

| Piece | Approach | LOC |
|---|---|---:|
| Shared widget/text/HUD layer | keep `ui.rs`, `screen_draw.rs`, `widgets.rs`, `font.rs`, `hud.rs`, `hud_layout.rs`, `hud_overlays.rs` | 14,133 |
| Title + world select + create world | prune `title.rs` (drop `Mode::Multiplayer`, `Mode::Realms`, `Mode::MultiplayerWarning`, ban/friends entry points) and `title/create_world.rs` + `world_management.rs`; drop `flat`, `buffet`, `experiments` only if you accept losing those vanilla create-world options | 3.5–5.5 k retained depending on how much of the vanilla create/edit/repair flow stays |
| Pause + death | `game/screens.rs`, drop split row/remote branches | 500 |
| Options | keep vanilla `Page::{Main,Video,Sound,Controls,KeyBinds,Mouse,Chat,Accessibility,Language,Font}` from `options_ui.rs`; point Video back at `Page::Video`; delete Horizon page machinery | 2,500 |
| Loading / startup title | `startup_menu.rs` pruned of Mods/packs/Realms branches + `loading_screen.rs` | 1,300 |
| Screen narration (if accessibility kept) | `screen_narrator.rs` + `screen_info.rs` | 1,700 |
| Toasts/subtitles/screen info | existing | 500 |
| **Total** | | **≈24–26 k** (~22–24 k if narration is dropped) |

Add ~4.8 k for chat and ~5.4 k for inventory/container/book/sign/merchant screens if "actually play
survival" is in scope → **≈34 k**. A from-scratch rewrite of title + options (rather than pruning)
costs ~3 k new code and removes ~4 k, so pruning is both cheaper and lower-risk.

## 3. Ranked removals by LOC

| Rank | Removal | LOC (gross) | Notes |
|---:|---|---:|---|
| 1 | Controllers (gilrs, DualSense, pad menus, glyphs, OSK, guide) | ~14.8 k (excl. 1.6 k controller page) | Horizon-only; **GATE** first, delete only if Steam Deck/console is out of scope. 821 refs, ~60 outside pad modules. |
| 2 | Multiplayer + Realms + social + server links | ~13.0 k | Realms alone 8.6 k. Keep `--server` parsing for launcher/test compatibility or return a clear error. |
| 3 | Horizon settings pages + shell (graphics, shaders, controller page, extras page) | ~10.1 k | Restores vanilla Video page; settings files can stay on disk. Overlaps rank 1 by 1.6 k (controller page). |
| 4 | Cosmetics + emotes | ~8.3 k | 155 refs in 13 files; also remove tab-list mark. |
| 5 | Splitscreen | ~6.8 k | Startup rewrite; biggest hidden coupling (`App`, pacing, windows, focus). |
| 6 | Extras/PvP/minimap/HUD editor | ~6.8 k | Mostly off-by-default; ~100 refs in `game.rs`. |
| 7 | Studio + agent/repro | ~6.7 k | Agent control is not behind `horizon-extras`; also removes `horizon-ctl ui` tree features. |
| 8 | Friends | ~5.3 k | Already feature-gated; deleting the crate is easy. |
| 9 | Narrator | ~3.5 k | Vanilla accessibility; **GATE**, don't delete. |
| 10 | Chat filter + anticheat | ~2.8 k | Server-only, no UI; cut with dedicated/LAN slice. |
| 11 | Audio device layer | ~1.2 k | Only if the fork must not link ALSA; loses all sound. |
| 12 | Tab list | 0.9 k | Low value; keep. |
| 13 | Pack screen Modrinth browser | ~0.5 k | Keep vanilla pack screen. |

Low-risk total (ranks 2,3,4,6,7,8,10 + pack): **≈53 k**. Controllers and splitscreen are the two
high-coupling items. Nothing in this slice touches worldgen/renderer, so a lite fork can plausibly
shed **~55–65 k LOC** (4–4.5 % of 1.44 M) before touching net/client code.

## 4. Traps

### 4.1 The `Screen` enum is a hub, not a list

`game.rs:955-1028` has 23 variants and an `id()` method that is a **native-mod API contract**
("A new variant must add one"). `grep` finds ~840 `Screen::` references across 91 files. Removing one
variant touches, at minimum:

- exhaustive matches in `game.rs` (draw at `:8223`, input at `:15281-15620`, scroll, click), `game/agent.rs:415`,
  `game/control.rs:240,295,1325`, `game/debug_keys.rs:74,129`, `game/debug_options.rs:517`,
  `game/ime.rs:26,134`, `game/narrator.rs:263`, `game/native_client_services.rs:76`,
  `game/native_text_field.rs:96`, `game/nether_portal.rs:606`, `game/pad_menu.rs:433,524`,
  `game/play_keys.rs:41,183`, `game/potions.rs:2118`, `game/chat.rs:1292`;
- `Screen::blurs_background` (`game/screens.rs:14-45`), `game/core_tests.rs:123` (all variants),
  `game/debug_options.rs:585` (list);
- agent/control screen names (`game/agent.rs`, `game/control.rs`) and `horizon-ctl` consumers.

Practical approach: keep the enum stable, make removed screens unreachable (delete their `Mode`/
constructors and draw arms later), or remove variants one per PR with compiler-driven fixes. Never
renumber/reorder the `id()` strings.

### 4.2 Translation keys are mandatory

AGENTS.md forbids hardcoded user-facing strings. Use `Text::translate`/`lang::get` (Horizon fallbacks
use `lang::get_or(key, english)`), never `Text::literal` for UI copy. Horizon's own keys live in
`crates/horizon-client/assets/horizon/lang/en_us.json` — 1,013 lines, 681 `horizon.*` keys, 87
languages. Vanilla keys come from the prepared `.local` resources, not the repo. Consequences:

- Deleting Horizon pages should also delete their keys (otherwise every language carries dead brand
  text), and lite screens must add keys there or reuse vanilla keys (`menu.singleplayer`,
  `options.video`, …).
- The existing code sometimes passes an English fallback (`get_or`) and occasionally raw strings
  (e.g. the world-recovery paragraph in `title.rs:2428`). Do not copy that pattern for new UI; the
  rule is keys, not literals.

### 4.3 Controller/agent registration is all-or-nothing per screen

`ui::button` records a widget and (with `action_button`) declares its controller action
(`ui.rs:535-585`; `widgets::record`/`declare_action` at `widgets.rs:178,367`). `settings_shell` does the
same for its rows. But:

- `graphics_style::button` (`graphics_style.rs:191`) only paints.
- `screen_draw::button` (`screen_draw.rs:554`) only paints and narrates.

A screen drawn with either must call `widgets::record`, `widgets::target`, or
`widgets::declare_action` itself (as `game/chat.rs:1160` does for a bare button).
`settings_shell::foot_button` records and targets its Done button but does **not** declare the
Done action; the page must call `widgets::declare_action(Action::Done, rect, true)` first
(`settings_shell.rs:1428`). If one widget of a
screen is registered and the rest are not, the pad switches that screen to focus/crosshair mode with
an incomplete map: controller users get stuck, and `horizon-ctl click ID` cannot find the rest. Register
**all** controls on a screen or none.

### 4.4 `horizon-extras` does not compile anything out

Already covered: 4 compile-time gates in 3 files plus one runtime bool. Delete files and call sites; flipping the feature only hides the
Settings/Mods buttons and disables cosmetics/friends/Discord/heartbeat. The fork guide explicitly
says the no-extras build is "best effort; CI builds only the default".

### 4.5 Splitscreen removal is an app rewrite

`run_event_loop` constructs `split::Split::new(game)` (`loading_screen.rs:32`) and `App` stores
`Box<split::Split>` (`:389`). `Split` owns `ApplicationHandler`, the frame limiter/clock, pad router,
per-seat options paths (`game/split.rs:71-85`), window creation and the compositor. Replacing it with
`App::Ready(Box<Game>)` needs a single-game `ApplicationHandler` impl (most of `impl for Split`,
`split.rs:592-874`) and checks of `options.split_guest` in saving/window/exit paths
(`game/window_handler.rs:102-104`, `game.rs:13022`, `screens.rs:263-529`). Budget ~300–500 LOC of new
glue; test window close, Esc/pointer grab, F11, VSync, pause.

### 4.6 Audio feature ≠ audio subsystem

`sound_engine.rs` is not gated and must stay: subtitles (`game/subtitle_hud.rs`), `horizon-ctl`
`heard`/`status`, and network sound capture read it. Without the `audio` feature you still resolve
`sounds.json` and fire notifications; you just have no output device. If you want a "no ALSA/udev
link" build, use the existing feature and keep the engine.

### 4.7 Narrator is woven into every screen

`widgets::begin_screen`/`Narratable`/`ScreenInfo` closures are everywhere; `screen_narrator.rs` (1.5 k)
is not an optional overlay. Gating it needs stubs for `Status`, `is_active`, `say*`, `InputType`,
`ScreenNarrator`, plus the options cycle (`options_ui.rs:703`) and Ctrl+B. Cutting the crate without
stubs breaks compilation in dozens of screens.

### 4.8 macOS dependencies are shared

`objc2*` in `horizon-client/Cargo.toml` is for split's `above_menu_bar`, but
`horizon-narrator/src/speech/mac.rs` uses `objc2`/`objc2-app-kit` too. Dropping split does not drop
those crates while the narrator stays.

### 4.9 Launch/control contracts

`--server`, `--quickPlayMultiplayer`, `servers.dat` seeding, `Screen::id` strings and `horizon-ctl`
screen names are consumed by the launcher, tests and agent control. If multiplayer is cut, keep the
flags parsed (clear error) and keep the `Screen` ids stable until the control API is revised.
`game.rs:17632-17641` seeds official/partner servers; remove that block with the feature.

### 4.10 Tests and parity harnesses

The UI files are test-heavy: `title/tests.rs` 2,626; `options_ui.rs` tests from 5,312 (≈3.1 k);
`pad_menu.rs` 2,588; `graphics_ui.rs` tests from 2,100 (≈1.4 k). Deleting a screen deletes its tests — fine — but also
retires parity fixtures (`pack_screen_fixture`, `chat_screen_fixture`, `tab_list_fixture`,
`container_screen_probe`, `hud_fixture`, `screen_layout_fixture`). If lite keeps CI green, prune the
harness lists too, or the parity runner will look for probes that no longer exist.

### 4.11 Branding checklist (all Horizon-only)

- Title: `title.rs:2615` version string, `:2623` not-affiliated notice, nightly label, `title_edition.rs`
  RUST EDITION banner, splash (splash itself is vanilla).
- Window: `loading_screen.rs:102` title "Horizon", app id `horizon`, boot paint fonts
  (`horizon-threads/boot_paint.rs`).
- Tab list Horizon mark (`tab_list.rs:614`), cosmetics presence, Discord "Playing Horizon",
  heartbeat ping, official/partner servers.
- Options: `Page::Horizon` hub, "Horizon Settings..." and "Mods" in the Main list
  (`options_ui.rs:3137-3155`), all `horizon.pages.*`/`horizon.options.*` keys.
- Chat: `horizon.chat.timestamp`, `horizon.chat.repeats`, `horizon.chat.search` (`chat.rs:514-874`) —
  Horizon additions on top of vanilla chat.

## 5. Suggested order of work

1. Make `--no-default-features --features audio` build and pass tests (today only default is CI'd).
2. Delete leaf, already-gated features: Friends, Discord/heartbeat, official servers, chat
   filter/anticheat (with the dedicated slice).
3. Delete Realms + multiplayer screens, keep `--server` parsing; prune title modes.
4. Delete Horizon settings pages; restore `Page::Video` as the Video Settings target; delete
   `settings_shell`/`graphics_style` users.
5. Delete extras/PvP/minimap/HUD editor and cosmetics/emotes (two large but shallow edit sets).
6. Gate (don't delete) narrator and controllers; only cut controllers if the target audience is
   keyboard/mouse only.
7. Replace `Split` with a single-game `App` last: it is the only change that can break startup,
   windowing and pacing at once.
