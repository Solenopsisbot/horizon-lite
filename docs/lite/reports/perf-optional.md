# Optional features — cross-cutting idle-cost inventory

Read-only static audit of `horizon-lite` @ `94ef964` (2026-11-08). No files were changed and no
cargo build was run. Every cost here is a **model** built from call counts and the code on the
call path; the only measured numbers are cited from the sibling reports (`perf-build.md`,
`perf-render.md`, `perf-tick.md`, `perf-modapi.md`, `perf-measure.md`). Where a row says
"~0", it means the feature is idled out by a branch, not that the code is absent.

Sibling reports already cover the renderer (`perf-render.md`), the tick loop (`perf-tick.md`),
the native API in depth (`perf-modapi.md`), build/PGO (`perf-build.md`) and the measurement
harness (`perf-measure.md`). This report is the **feature-by-feature cross-cut**: what each
optional subsystem does when nobody uses it, and whether deleting it can raise FPS.

---

## 0. The build this describes (important)

This fork's default feature set is **`default = ["audio"]`** in both
`crates/horizon-client/Cargo.toml:112` and `crates/horizon-client-lib/Cargo.toml:117`.
That means the shipped `play.sh` build has:

- **no `controllers`** (no gilrs, no DualSense, no libudev) — only the stub in
  `game/pad.rs:133`;
- **no `horizon-extras`** (no cosmetics service, no Discord, no friends, no heartbeat, no
  official/partner server seeding), because every use is a `cfg!` that folds to false;
- **content mods have no cargo feature at all**: the `horizon-mods` loader and registry are always compiled.

Everything else in this report — PvP HUD, minimap/extras HUD, Studio, agent/control, debug,
narrator, splitscreen, telemetry session, native mod API, shader packs, resource/data packs,
`remote.rs`/`lan/` — is compiled and reachable in that default build. Several of the "optional"
features are therefore *runtime-inert but linked* (Tier B below), while a small number still
execute bookkeeping every frame/tick even though nobody switched them on (Tier A).

The sibling `perf-measure.md` baseline on a GTX 970, 720p offscreen, RD 12: village p50
**0.76 ms/frame**, mountain **2.58 ms**. At ~1000 fps a 10 µs/frame cost is 1.3 % of a frame;
at a 60 fps cap (16.7 ms) the same 10 µs is 0.06 %. Keep that scale in mind: most rows below
are single-digit µs per frame, i.e. noise at 60 fps and low-single-digit percent only in an
uncapped benchmark.

---

## 1. Inventory

Legend: **F** = per frame (redraw), **T** = per game tick (20/s, `tick_remote` on the window and
`tick_world` on the integrated server), **E** = per entity/mob, **B** = per block event
(random/scheduled tick, neighbour/shape/signal update), **P** = per inbound packet,
**I** = per input event, **L** = per loop turn (`about_to_wait`, usually 1–2/frame).

| # | Feature | Idle call sites (file:line) | Freq | Cost when idle | Cost when active | Delete LOC | Risk |
|---|---|---|---|---|---|---|---|
| 1 | **Cosmetics + emotes + emote wheel** | `game/cosmetics.rs:440` `enabled()`; `:446` `cosmetics_frame`; `game/scoreboard.rs:821` `flush_skin_slots` (called from `draw_tab_list` at `:839` and `game.rs:7898`; calls `cosmetics_frame` at `:830`); `game/cosmetics.rs:569` `tick_others_emotes` via `game/emotes.rs:213` ← `game.rs:10808` (server) & `game/remote.rs:6954` (client); `game.rs:9764` `cosmetics_fx_geometry`; `game/creatures.rs:7772`, `game/perspective.rs:816,942` `cosmetics_geometry`; `game/names.rs:296` `cosmetics_marks`; wheel: `game.rs:8242,15315`, `game/emote_wheel.rs:48` | F, T, per named entity, per rendered player | **Default build: ~0.** `enabled()` is `cfg!(horizon-extras) && …` → false, so `cosmetics_frame` returns after one branch, `tick_others_emotes` after 2 Option checks, `cosmetics_fx_geometry` after one, `worn()`/`cosmetics_marks` after a `None` client lookup. ~1–2 µs/frame total, no allocation. **With `--features horizon-extras`: not idle** — see row 1a. | Account owner check + presence sync spawn HTTP threads; `Cosmetics` fetch thread per UUID; per-frame `settle`/`due` + `baked.retain`; `tick_others_emotes` locks the feed mutex and writes `m.emote = None` for **every mob** each tick when others' cosmetics are hidden; per-wearer models/trails/auras; TTS-free. Emote: pose math per playing emote; camera pull. | ~8.1k (`horizon-cosmetics` 6,183 + `game/cosmetics*` 1,501 + `emotes.rs` 228 + `emote_wheel.rs` 216) + refs in 13 render/mob files | LOW (13 touch points, no gameplay effect when off) |
| 1a | **Cosmetics, if `horizon-extras` is enabled** | same | F, T | `horizon_cosmetics::ON_BY_DEFAULT = true` (`horizon-cosmetics/src/lib.rs:48`): the service is **on by default** — per-frame account sync machinery, a `Cosmetics` fetch thread, a `Feed` poll thread, HTTP owner/presence requests, plus the per-tick O(mobs) emote clear. | as above | — | LOW mechanically, **product/privacy decision** |
| 2 | **Extras HUD + FPS counter + minimap** | `game.rs:16292` `extras_frame`; `game/extras.rs:60` `update_minimap` (2× `minimap_wanted()`/`native_minimap_now` at `:162/:168`), `:63` `fps.record`, `:64` `native_frame`, `:65` `pvp_frame`; `game.rs:8046`/`extras.rs:243` `draw_extras`; `extras.rs:267` `draw_pvp_hud`, `:268` `native_hud`; `game.rs:7878` glint texel; `render/extras.rs` settings only | F | ~2–6 µs/frame: **5 empty native dispatches** (minimap ×3, `native_frame`, `native_hud`), one `Minimap::clear()` (empty map/vec), `FpsCounter::record` push + a **full 5-second window copied into a Vec and sorted every 0.5 s** (300 samples at 60 fps, ~5,000 at 1,000 fps), one relaxed atomic store (`pvp_frame`). The minimap **does not exist as a built-in**: `minimap_wanted()` returns only `native_minimap_now()` (`game/extras.rs:161`), so `render/minimap.rs` is reachable only from a native mod; the Extras page no longer lists FPS/keystrokes/minimap (`render/extras.rs:634-666`). | Minimap scans tiles within an explicit **300 µs/frame budget** (`game/extras.rs:31,193-200`) + 128×128 compose/upload; FPS sort; native mod panels. | ~2.6k (`render/extras.rs` 1,257 + `extras_ui.rs` 268 + `minimap.rs` 682 + `game/extras.rs` 283 + `extras_hud.rs` 143) + shared options rows | LOW |
| 3 | **PvP HUD + HUD editor** | `game/pvp.rs:180` `pvp_frame`; `:249` `draw_pvp_hud`; `game.rs:7878` `glint_texel`; `render/pvp.rs:191` `view_day_time`, `:197` `view_weather`; `game.rs:8256` `draw_hud_editor` (screen only); `game/pvp.rs:559` `hud_editing` | F | ~0.5–1.5 µs/frame: all 13 widget switches default false (`render/pvp.rs:626-680`), so `draw_pvp_hud` does `hud.any()` + `boxes.clear()` and returns; `pvp_frame` is one atomic store; time/weather read two settings. | Text layout only when a widget's value changes; per-frame text quads; custom crosshair/outline fill only if enabled. | ~3.6k (`render/pvp.rs` 1,835 + `pvp_hud.rs` 792 + `game/pvp.rs` 764 + `hud_editor.rs` 255) + options page | LOW |
| 4 | **Studio recorder / replay** | `net.rs:1002` mutex+`is_active` **per inbound packet**; `net.rs:343,350-358` recorder lock; `game/remote.rs:7835,7876` `record_clientbound` per tick when moved; `game.rs:14683` `advance_studio_replay` per frame; `:9538,9749,14008` freecam/replay checks | P, T, F | **~15–25 ns × every received packet** (uncontended `Mutex<Option<StudioRecorder>>` lock + Option check). In SP that is all packets, including every chunk packet while streaming. `advance_studio_replay` is one Option check. | Filters/encodes every kept inbound packet (privacy filter, AddEntity UUID rewrite), writes `.mcpr`; replay dispatches packets per frame; freecam spline. | ~4.0k (`game/studio.rs` 950 + `src/studio/` 2,981) + net hooks | LOW |
| 5 | **Agent / control / events / ui_control** | `game/control.rs:186` `poll_control` ← `game/window_handler.rs:148`; `:194` `widgets::end_frame`, `:195` `narrate_screen`, `:196` `poll_repro`, `:197` `advance_agent`, `:198` `ui_wait.ready`, `:201` control loop; `game.rs:7565` `agent.hold_server` per tick; `input_trace.rs:404-411` `tracing_input` per input | L, T, I | ~1–2 µs/loop turn: 6 early-out calls; control socket only starts with `--control` (`game.rs:843`); `agent_command` is only reached from `control.rs:409`; the per-frame `advance_agent` is two early-outs; input tracing returns after 2 bool checks. | JSON command handling, per-frame task stepping, socket threads, replay drivers. | ~11k (`agent*` 2,957 + `game/control.rs` 1,742 + `control.rs` 794 + `events.rs` 362 + `ui_control.rs` 220 + `repro.rs` 1,972 + `horizon-ctl` 2,635 + `horizon-mcp` 476) | LOW |
| 6 | **Debug overlays / charts / entries / perf overlay** | `game.rs:7572-7573` `tick_debug_keys` + `tick_debug_charts` **every tick, before the remote early-return**; `game/debug_keys.rs:224` (client: locks `session.counters`, logs bandwidth **every tick** + packet rates every 20); `game.rs:7869`/`game/debug_keys.rs:300` `draw_debug_overlay` → `any_enabled`; `game.rs:14007` `debug_gizmos` (+ `:14052` crosshair) → several `debug_entry` linear status scans; `game.rs:16348,16357-16422,16423` frame graph/stats/chart log; `game.rs:7870` `frame_graph.draw`; `debug_keys.rs:195` crash countdown | T, F | ~2–6 µs/frame + ~0.3 µs/tick: `DebugEntries::any_enabled` walks the 9 default statuses and each `enabled()` does a linear `status()` scan (≈O(n²) string comparisons) every frame F3 is closed; `tick_debug_charts` locks counters and pushes one `VecDeque` sample per tick on the window; `debug_charts.frame_times.log` pushes one sample per frame; `frame_graph.record` + `FrameStats::record*` + `Session::frame` per frame. All bounded, no heap growth. | F3 builds ~30–60 strings (cached 20 Hz in `debug_paint`), server debug lines per tick, charts draw. | ~7.5k (debug_overlay 826 + debug_chart 644 + debug_entries 509 + perf_overlay 110 + debug_keys 490 + game/debug_keys 1,427 + debug_options 614 + debug_lines 581 + debug_renderers 292 + tick_profile 247) | MED — F3 is vanilla; delete only the *recording*, not the screen |
| 7 | **Narrator / screen narration** | `game.rs:17663` `narrator::start` (always for a client) → `horizon_narrator::init` spawns the TTS thread; `game/control.rs:196` `narrate_screen` → `screen_narrator.rs:587`; `horizon_narrator::is_active()` locks a global mutex **per frame and per key press** (`game/narrator.rs:222`); widget narration recorded per widget per frame when `NARRATING` (`render/widgets.rs:915-1006`); `game.rs:15120` `narrate_input` per input event | F, I, per widget | **Not off when the setting is Off.** `is_active()` means "the TTS library opened", not "the narrator is enabled" (`horizon-narrator/src/lib.rs:177`, `speech.rs:123`); on Linux flite is usually present, so `NARRATING` stays true and every screen rebuilds its narration tree (String allocations per button/slider) every frame. In-world cost is ~1–2 µs/frame (mutex + step); a dense options/inventory screen is the visible cost. If flite is absent, ~0. | Speech synthesis on its own thread; no extra tree cost (already built). | ~3.1k (`screen_narrator.rs` 1,530 + `game/narrator.rs` 344 + `horizon-narrator` 1,447) + widgets narration | MED (35 refs, widget API) |
| 8 | **Controllers / pads** | `window_handler.rs:152` `poll_pads` ← `game/pad.rs:271`; `pad.rs:281-289` disabled path; `pad/hardware.rs:219` `read()`/`start()`; default `PadSettings.enabled = true` (`horizon-client-input/src/gamepad.rs:609`) | L (1–2/frame) | **Feature off (default): hardware polling is compiled out, but the pad state machine still runs** — context, 16-button edge scan, merge, deadzone, activity, health, guide — ~1–4 µs/frame. **Feature on:** `GilrsBuilder::build()` at first poll (udev/evdev scan, can be tens of ms startup) + `gilrs.next_event()` drained every loop turn + `gamepads()` scans when no pad is active. No pad does **not** mean no syscalls. | Gilrs events, rumble, DualSense HID output/adaptive triggers/lightbar, pad UI. | ~9.6k (client `pad*`/`pad/` 7,092 + `horizon-dualsense` 1,345 + `horizon-client-input/gamepad.rs` ~1.2k) | LOW–MED |
| 9 | **Splitscreen** | `loading_screen.rs:31` `Split::new` **always wraps the game**; `split.rs:727` `about_to_wait`: `:748` `sync_setup()` (one page check), `:750` `stop_routing()` (one `Option::take`), then `host.about_to_wait`; `split.rs:600` `window_event` one `surfaces.is_empty()` branch; `game.rs:7903`/`server_packs.rs:578` `draw_split_hud` early-outs | L, F | **~0.1–0.3 µs/frame** with one player; no compositor, no extra `Game`, no window. | N games render offscreen + compositor; per-player options/threads. | ~3.4k (`split.rs` 928 + `split/` 2,502) | LOW–MED (owns `App::Ready`) |
| 10 | **Telemetry / heartbeat / benchmark / spans / stopwatches / GPU timer** | `game.rs:17606` consent check; `render/telemetry.rs:257` `Session::frame` per frame; `game.rs:16434` `perf.frame`; `render/spans.rs:88` `guard()` at **110 call sites** (`game.rs` 74); `game.rs:17629` `heartbeat::start` (feature off by default); `game.rs:17672` Discord (feature off); `gfx.rs:2781` `GpuTimer::new`, `:9658` begin, `:11428/11565` end/resolve — **unconditional if the adapter exposes timestamps**; `benchmark.rs` CLI only; `stopwatches.rs` save/load only | F, T | ~0.5–2 µs/frame from session/frame-graph/stats bookkeeping; 110 span guards each ~1 atomic + 2 TLS reads when off; **GPU timestamp query + resolve + 16-byte readback + `map_async`/`device.poll` every frame** — the perf-build audit estimates **0.3–1.5 %**; one extra mixer mutex lock per frame from `audio.set_listener`. | With perf consent: `spans::record_here(true)` turns every guard into 2 clock reads (`Instant::now` + `clock_gettime(THREAD_CPUTIME)`), ~74 spans/frame → ~0.1–0.5 ms/frame. Heartbeat: one HTTP ping/minute. Benchmark: full scenario driver. | ~6–7k (telemetry 585 + benchmark 616 + heartbeat 74 + stopwatches 121 + spans ~800 + `horizon-telemetry` 3,308 + `horizon-bench` 757 + `gfx/timing.rs` ~350) | LOW |
| 11 | **Chat filter / anticheat (client paths in `lan/`)** | `lan/anticheat.rs:124` `anticheat_tick` per server tick (first line: `let Some(ac) … else return`); `lan/hub/chat_filter.rs:104` `chat_allowed` per chat/sign/book/anvil text; `lan/prediction.rs` types are used by the hub for movement validation in SP (`hub.rs:3071,3155,3536`) | T, per chat | ~1 branch/tick when no anticheat; filter not installed in SP (`hub.chat_filter = None`), so one Option check per text. | Filter normalises/matches every chat/sign/book string; anticheat replays movement records per guest per tick. | ~3k (`horizon-anticheat` 1,052 + `horizon-chat-filter` 1,171 + `lan/anticheat.rs` 597 + `lan/hub/chat_filter.rs` 247; some glue shared) | MED — `prediction.rs` borrows `horizon_anticheat` types; moving `slack`/`near` out is required |
| 12 | **Advancements / stats / scoreboard triggers** | `game/stats.rs:253` `award_stat` (40+ call sites, mostly per action), `:276` `tick_stats` per tick; `game/advancements.rs:768` `trigger` (event-driven), `:1151` `tick_advancements` per server tick; `game/scoreboard.rs:474` `tick_scoreboard` per tick, `:140` `load_scoreboard` once | T, per action | **Vanilla cost, not optional.** Per tick on the server: `play_time`/`total_world_time`/`time_since_*` awards allocate a `String` pair per stat (`stats.add` pushes to `events` and `dirty`); `stat_criteria_changed` returns immediately when no objectives; `tick_advancements` returns immediately on the client (`remote.is_some()`), runs one `minecraft:tick` trigger per tick on the server. ~1–3 µs/tick + allocations. | Condition JSON evaluation on each action; toasts; sidebar redraw. | 6,574 (must stay) | HIGH — persistence/teams |
| 13 | **Native mod API dispatch** | 507 generated `dispatch_*` (`target/.../out/mod_api_generated.rs`); 655 gameplay wrapper call sites (`perf-modapi.md`); per frame: `native_frame` (`game/extras.rs:64`), 13 HUD layers × pre/post (`native_hooks.rs:10825,10827`), camera/fog/visuals/emissive/highlight/world-hold/zoom/minimap (~46 total); per packet: `native_client_packet` (`remote.rs:3585`); per block event, server side: **33 hooks** in the `GameLevel` impl (`game.rs:1354-1730`: `block_changed`, `neighbor_changed`, `block_redstone`, `analog_output`, `update_shape`, `random_tick`, `tick_block`, signals, fluid, bonemeal, piston…); per tick: `native_tick`, joins/leaves, inventory; per entity tick: **gated** by `TickRound::listening` (`native_ticks.rs:58-108`) | F, P, B, T | **Empty list is cheap per call (~3–8 ns) but there is no global fast path.** `dispatch_*` always does OnceLock load + `place_in` pointer check + `Entered` iterator; `mods()` (`mod_api.rs:863`) returns `&[]`. 46 frame dispatches ≈0.3 µs/frame; 13 tick dispatches ≈3.5 µs/tick (perf-modapi). **Per block event is the hot part:** `native_authoritative` (`game.rs:1165`, `mod_api_host.rs:90`) means "this Game is the server", **not** "mods are installed", so every random tick, scheduled tick, neighbour/shape/signal query on the integrated server pays 1 empty dispatch even with zero mods. Model: tens of thousands of random ticks/s at RD 12 → ~0.1–0.5 % CPU, more in redstone-heavy worlds. Several hot spots *do* check `mods().is_empty()` (40 sites, e.g. `stats.rs:255`, `creatures.rs:7501`), the per-entity tick batch has a listener gate, but the per-block and per-packet hooks do not. | One virtual call per hook per mod + thread-local crash guard + JSON/host work; a single trivial mod turns off the entity-culling precheck (`creatures.rs:7501`), which can make dense scenes **slower** than vanilla. | ~47.4k (client `native_*.rs` 35,653 + `mod_api.rs` 1,402 + render `native_*` 5,844 + generator 2,942 + 160 fragments/JSON) + 600 KB generated | MED–HIGH |
| 14 | **Shader packs** | `gfx.rs:6377,9671,9697` etc. — ~10 `Option`/bool checks per frame in `Renderer::render`; `game.rs:13064` `picked_pack_shape` only on renderer rebuild; `game.rs:14324` `shader_pack_inputs` only when a pack is loaded | F | **<0.1 µs/frame** at default `shader_pack: ""` (`graphics.rs:835`): `pack_post` is `None`, no passes, no extra pipelines. The 25k+ LOC and 46 extra WGSL files cost build time/disk, not frame time. | Shadow pass + 10–40 post passes; typically 2–4× frame time at 720p (perf-render). | ~31k (CUTS: 29,649 shader/pack + 1,360 glue) | LOW–MED (locale/format code shared) |
| 15 | **Resource / data packs, server packs** | `render_frame` pack-reload overlay check; `game/server_packs.rs:371` `tick_server_packs` per frame (`drive_pack_reload`, `drive_pack_browser`, notifier retain); `pack_pixels().pack()` per frame (no-op once packed) | F, reload | ~0.5–1 µs/frame with no server packs/reload; O(1) checks. There is **no "no packs" state**: vanilla's own pack is always loaded, and textures are resolved through it every frame. | Pack reload rebuilds atlas/models/atlas slots; server-pack download/prompt. | must stay (vanilla substrate) | — |
| 16 | **Multiplayer/remote surfaces in SP** | `game/remote.rs:6527` `tick_remote` (**the game loop — keep**); `poll_remote` per frame; `game/scoreboard.rs:839`/`remote.rs:5858` `update_remote_skins` **every frame the tab list is hidden**; `game.rs:8209-8211` tab-list layer; `draw_tab_list` → `flush_skin_slots` (`scoreboard.rs:839`, also runs `cosmetics_frame` at `game/cosmetics.rs:446`) | F | **The one real unconditional per-frame cost in this row:** every frame while playing, `draw_tab_list` runs `flush_skin_slots` (atlas-slot bookkeeping) and `update_remote_skins` — `skin_entries` clones a `Textures` per listed player into a `Vec`, builds `slim`/`capes` HashMaps, collects a `HashMap` of player mobs by scanning **all mobs**, then re-resolves skins. In SP ~3–10 µs/frame + 6–10 allocations. Menus (`multiplayer.rs` 3,008, `lan_screen.rs` 1,730, `social_screen.rs`, `server_links.rs`, `gossip.rs`, `friends_screen.rs`) are runtime-dead unless opened. `add_official_server`/`add_partner_servers` are `cfg!`-false. | Joining/streaming/handling packets; skins downloads; server list pings. | UI-only: CUTS 5,292 + `multiplayer.rs` 3,008 + `lan_screen.rs` 1,730; **`remote.rs`/`lan/` are not deletable** | LOW for UI, HIGH for the loop |
| 17 | **Content mods (`horizon-mods`)** | loader/registry only at startup and on pack/creative-tab paths; `game/mods.rs`, `mod_content.rs`, `mod_registry.rs`; no per-frame loop of its own | startup/pack | ~0 idle; registries built once. | WASM content load, mod menus, creative tabs. | CUTS 18,524 | MED |
| 18 | **Audio (default on; for completeness)** | `game.rs:13932` `audio.set_listener` per frame (mixer mutex); cpal stream thread; `sound_engine` tick per tick | F, T | one uncontended mixer lock + listener write per frame; stream callback runs on its own thread. | mixing/decoding/positional sounds; `symphonia` Vorbis. | `audio` feature; cpal/alsa; `symphonia` is **unconditional** in render | LOW |

Notes on the table:
- "Delete LOC" for rows that share `options_ui.rs` excludes the shared file; CUTS.tsv's 4,413
  figure for extras UI + Studio is the better headline for the combined cut.
- `render/minimap.rs` is **not dead code by intent** — it is the native-mod minimap. With zero
  mods it is unreachable, but deleting it changes the mod API contract.
- F3 debug is vanilla. The deduplicated 7.5k above is the whole F3 implementation; a fork that
  wants F3 cannot delete most of it. The deletable *instrumentation* is the always-on recording
  (`tick_debug_charts`, `frame_times.log`, `frame_graph`, `FrameStats`, `Session`), ~1–2k.

---

## 2. Ranked "delete for speed" order

### Tier A — things that cost real time while idle (ranked by expected payoff)

Percentages below are shares of an **uncapped benchmark frame** (~0.8–2.6 ms in `perf-measure.md`).
At a 60 fps cap (16.7 ms) divide them by roughly 20; at 1000 fps they are at face value.

1. **Instrumentation that runs unconditionally.** GPU timer (0.3–1.5 % per `perf-build.md`),
   per-frame `FrameGraph`/`FrameStats`/`Session::frame`/`debug_charts.frame_times.log`, per-tick
   `tick_debug_charts` bandwidth logging. Fix: create `GpuTimer` only while the Overlay/F3/stats
   consumer is on; put the debug-chart logging behind `self.debug`; keep `FrameStats` only when
   `--control`/benchmark. Est. **0.3–1.5 %** recovered (the only row in this report with a
   percent-scale number from a sibling audit). Delete: ~1–2k of the 7.5k debug block if F3 stays.
2. **Native mod API empty-list fast path.** Add `if mods.is_empty() { return; }` to the generated
   `dispatch_*` prologue (one line in `horizon-mod-api-gen`), and to `handle_packet` /
   `GameLevel` block hooks. This is not a deletion; it neutralises the per-block cost without
   touching the 47k LOC. Est. **0.1–0.5 %** in a normal world, more with redstone/farms.
   Deleting the whole API is the same runtime win plus 47k LOC and the largest build-time win,
   but it is the riskiest change in the tree.
3. **Skin/tab-list per-frame resolution.** `draw_tab_list` (`game.rs:8209`) currently calls
   `update_remote_skins` on every frame the tab list is hidden, and `flush_skin_slots` every
   frame. Gate the skin resolution on `shown || skins_revision changed`, and poll downloads at
   1 Hz instead of per frame. Est. **0.05–0.3 %** and removes 6–10 allocations/frame. ~0 LOC
   deleted; the highest payoff-per-risk change in the report.
4. **Narrator.** Deleting it removes the always-built narration tree (on screens), the
   per-frame/per-key `is_active` mutex and the TTS thread. In world ~0.02–0.1 %; on menus the
   per-widget String churn is visible. ~3.1k LOC, MED risk.
5. **Studio recorder.** Remove the `recorder.lock()` from `receive_play` (or make it an
   `AtomicBool` + `OnceLock`); per-packet mutex is small but it is on the hottest packet path
   and costs even when idle. ~4.0k LOC, LOW risk, biggest cleanup of the v0.2 list for a
   single-player fork.
6. **Pads.** `controllers` is already off by default, but `poll_pads` still runs the whole state
   machine every loop turn. Either default `PadSettings.enabled=false` in the lite config or
   delete `pad*`/`pad/` + DualSense (~9.6k). Est. 1–4 µs/frame. LOW–MED.
7. **Extras HUD/minimap bookkeeping.** Delete or gate `extras_frame` (`FpsCounter`, minimap
   clear, `native_frame`) when no native mod asks; ~2.6k LOC. Est. <0.05 %.
8. **Agent/control, splitscreen, shader packs, PvP HUD, cosmetics, content mods, multiplayer
   UI, chat filter/anticheat.** Idle cost is a handful of branches (see table). Delete them for
   binary/build/attack-surface reasons, not FPS.

### Tier B — dead weight in the binary / build, zero idle frame time

Ranked by build-time and LOC payoff (not FPS):

1. **Native mod API** — 47k LOC, 600 KB generated source, `syn` parse of 466 `game/` files every
   build (the largest build-time lever; `perf-build.md`/CUTS p3). Runtime only via Tier A #2.
2. **Shader packs** — ~31k LOC + 46 WGSL files + `naga` features; zero default FPS
   (`perf-render.md` §2). Keep vanilla `post_chain.rs`/`post_glsl.rs`.
3. **Content mods** — 18.5k; startup-only.
4. **PvP HUD + HUD editor + extras UI + minimap** — ~6.3k standalone + options pages; defaults
   off; minimap already only reachable from a mod.
5. **Cosmetics + emotes** — 8.1k; already runtime-off in the default build.
6. **Agent/control/repro + horizon-ctl + horizon-mcp** — ~11k; runtime ~1–2 µs/frame; `agent_command` was only reachable from the control socket.
7. **Splitscreen** — 3.4k; one bool/frame when off.
8. **Multiplayer-only UI + friends/social/server links + dedicated code** — ~10k+5k; inert in SP
   except the `Screen` enum touch points.
9. **Chat filter/anticheat** — ~3k; dedicated-only in practice; `prediction.rs` coupling is the
   risk.
10. **Advancements/stats/scoreboard, resource/data packs, `remote.rs`/`lan/`** — keep (see §3).

**Consequence for the current plan:** every item in the v0.2 table (agent/dev tooling,
multiplayer UI, dedicated, extras+cosmetics+Studio, shader loading, tutorial/GameTest) is Tier B
or near-zero Tier A. The 40-hour v0.2 programme improves cold build, binary size and maintenance;
it does **not** raise FPS meaningfully. The only runtime-relevant planned item is the native mod
API (v0.3), and its cost can be removed with a one-line generator guard years before the
deletion lands.

---

## 3. What MUST stay for single player

- **`game/remote.rs` + `lan/` + `game/integrated.rs` + `game/levels.rs` + `net.rs` +
  `horizon-protocol`.** Single player is a client of an in-process server thread
  (`AGENTS.md`, `docs/lite/PLAN.md` §1): the window runs `tick_remote()` and the world runs on
  the server thread. Deleting these is a 250–400 h re-port, not a cleanup. The in-memory pipe
  and packet loop are the game loop.
- **`game/lan_actions.rs`, `game/lan*.rs`, `lan/hub`** — block placement, chat, inventories,
  movement validation and scoreboard sync arrive as packets even in SP.
- **`horizon-server-files`** — used outside the dedicated server by `control.rs`,
  `game/tempban.rs`, `game/chat_filter.rs` and `remote.rs` profiles. Do not delete with
  `game/dedicated*`.
- **Advancements / stats / scoreboard** — persisted world state; `persist.rs` reads the
  scoreboard for team membership. Deleting silently changes save round-trips.
- **Resource/data packs** — vanilla's own pack is always active; JVM-format pack reading is the
  substrate, not an extra.
- **Skins/`update_remote_skins`** — needed for the player model and tab list (but see Tier A #3:
  the *per-frame cadence* is not required).
- **Audio** if the intent is a normal game; `audio` is the only default-on feature.
- **`shader_packs::picked_pack_shape` / `post_chain`/`post_glsl`** — vanilla screen effects
  (spider/creeper/underwater) use the same post stack; delete the pack loader, not the effects.
- **`horizon-anticheat::prediction`'s `slack`/`near`** are called by the hub for movement
  validation in SP; move them before deleting the crate.

---

## 4. The single biggest surprise

**The plan has the cost model upside down: the features you would delete for speed are already
runtime-inert, and the one optional feature with a real steady-state cost — the native mod API —
costs that money *because it is not gated on "no mods".**

Concretely: the default build is `default = ["audio"]`, so cosmetics, emotes, controllers,
Discord, friends and heartbeat are already compiled/featured out or reduced to a handful of
branches. PvP HUD, minimap, Studio, splitscreen, agent control, shader packs and chat
filter/anticheat are all default-off or event-driven; deleting them buys build time and bytes,
not FPS (the renderer sibling reaches the same conclusion for LOD/shaders/HDR/OIT). Meanwhile
the native mod API — the item the plan defers to v0.3 as a *build-time* problem — dispatches on
**every random tick, scheduled tick, block change, neighbour/shape update and redstone signal
query** on the integrated server, because `native_authoritative` (`game.rs:1165` /
`mod_api_host.rs:90`) means "this Game is the server", not "mods are installed". With zero mods
that is 33 empty hooks per block event, plus one per inbound packet (`remote.rs:3585`) and ~46
per frame. A one-line `if mods.is_empty() { return; }` in the generated dispatch prologue
neutralises almost all of it; the 47k-line deletion is not required to get the speed.

The runner-up surprise is the narrator: `horizon_narrator::is_active()` means "the TTS library
loaded", not "the narrator setting is on". On a machine with flite, setting Narrator to **Off**
still records a narration tree for every widget on every screen, every frame
(`render/widgets.rs:915-1006`, `screen_narrator.rs:587-644`).

A third, smaller one: the built-in minimap/FPS/keystrokes extras no longer draw anything. Their
settings are still parsed (`render/extras.rs:313`), but the only renderer is
`native_minimap_now()` (`game/extras.rs:161`); `render/minimap.rs` (682 LOC) and `FpsCounter` are
reachable only from the native mod API.

---

## 5. Arithmetic, caveats, reproduction

- `self.native_*()` textual call sites: 970 outside `native_hooks.rs` (951 excluding the
  `native_authoritative` field); the sibling `perf-modapi.md` counts 655 gameplay wrapper sites
  by function scope. Generated dispatchers: 507; catalog hooks: 510 (432 + 78 fragments).
- Per-frame numbers assume one window, no mods, no shader pack, default settings, SP world.
  `about_to_wait` can run 1–2× per redraw, so L-frequency items are 1–2× the F figures.
- The 0.3–1.5 % GPU-timer figure is from `perf-build-summary.md`, not re-measured here.
- No profile counters exist for these paths. To measure: `HORIZON_SPIKES=8` + `horizon-ctl
  stats` (frame/tick spans); temporarily add `spans::time` around `draw_tab_list`,
  `extras_frame`, `poll_control`, `poll_pads`, `tick_debug_charts`; and A/B with `mods` forced
  empty versus the generated fast-path build.
- Files worth reading first: `docs/lite/CUTS.tsv` (LOC/risk), `docs/lite/PLAN.md` §4,
  `perf-modapi.md` §2–3, `perf-render.md` §2, `perf-tick.md` §1.
