# Native mod API: runtime cost vs build-time cost

Read-only static analysis of `horizon-lite` at `94ef964`. No cargo build, no profiling run:
every nanosecond figure below is a cost **model** built from the call counts and the generated
code, not a measurement. Counts (files, lines, call sites, symbols) are measured with
`grep`/`nm`/`wc` and are reproducible.

---

## 1. Measured surface

| thing | count | how measured |
|---|---:|---|
| hooks in `native-hooks.json` | 432 | `len(d["hooks"])` |
| — of which `listen` / `cancel` / `collect` / `replace` | 250 / 114 / 41 / 27 | catalog `mod_api.contract` |
| generated `dispatch_*` functions | **507** | `grep -c '^pub fn dispatch_' target/…/out/mod_api_generated.rs` |
| generated dispatch source | 598,840 B / 8,284 lines | `wc` |
| generated `Host` trait | 194,821 B / 2,381 lines, 429 methods | `wc`, `grep -c 'fn '` |
| generated host impl | 46,910 B | `wc` |
| `native_hooks.rs` wrapper methods | 621 | `grep -c 'pub(super) fn native_'` |
| `native_hooks.rs` size | 13,391 lines, **3,799 of them `///`** | `wc`, `grep -c '^///'` |
| call sites of those wrappers in gameplay code | **655** (728 incl. host helpers) | per-file `fn`-scope scan |
| files that name `mod_api::` | 59 (49 non-test) | `grep -rl` |
| `dispatch_*` symbols linked into `target/debug/horizon-client` | 505 → 206 KiB `.text` | `nm -S` |
| all `native_*`/`mod_api`/`mod_api_host` symbols | 3,692 → 0.6 MiB `.text` (debug) | `nm -S` |
| `game/` files `syn`-parsed by `build.rs` every build | 466 files / 305,788 lines | `find`/`wc` |

## 2. Dispatch sites by frequency class

The list is long-tailed: 507 generators, but only ~50 hooks are reachable from a loop. Classes
below are from reading the call paths, with one example each.

**Per frame, fixed (~46 dispatches)**
`native_frame` `game/extras.rs:64`; `native_gui_layer_pre/post` ×13 layers = 26
(`native_hooks.rs:10825,10827`, called from `game.rs:7992…8209`); `native_camera_pose`
`game.rs:13900`; `native_compute_fov` `fov.rs:143`; `native_compute_fog_color`/`native_render_fog`
`render_tick.rs:171,186`; `native_frame_visuals` `game.rs:14020`; `native_emissive` `game.rs:14026`;
`native_block_highlight` `game.rs:14083`; `native_gui_render_post` `game.rs:14203`;
`native_health_hud` `game.rs:8148`; `native_hud` `extras.rs:268`; `native_world_hold`
`game.rs:14833`; `native_world_drawn` `gfx.rs:11382`; `native_hand_drawn` `gfx.rs:11777`;
`native_render_needs` ×2 `gfx.rs:6851,9691`; `native_minimap` ×2 `extras.rs:162`; `native_zoom`
×3–5 `extras.rs:219`; `native_render_hand`/`_pose` `game.rs:12778,12791`; `native_world_primitives`
`world_primitives.rs:43`.

**Per visible entity, per frame**
`native_mob_submit` `creatures.rs:7649` → `native_mob_draw.rs:105`; `native_player_render_listened`
`native_mob_draw.rs:155`; `native_entity_outline` `glowing.rs:29` (mobs *and* every dropped item,
`item_draw.rs:686`); mod block entities only: `native_block_entity_submit`
`native_block_entity_draw.rs:501`.

**Per tick (20/s), fixed**
`native_inventory_ticks` `game.rs:7604`; `native_tick` `7656`; `tell_native_now` `7657`;
`native_joins_flush` ×5 `7664,7692,7741,7765`; `native_leaves_flush` ×4 `7740,7751,7758,7766`;
`tick_mod_container_viewers` `7753`; `native_level_tick_pre/post` `levels.rs:536,560`;
`native_player_tick_pre/tick` `lan_actions.rs:4180,4281`; `native_entity_tick_listened` ×4
(`native_ticks.rs:58`).

**Per entity per tick — gated off**
`native_entity_tick_pre/post` go through `TickRound::listening` (`native_ticks.rs:84,99,117,130`).
With no mod listening they cost 4 dispatches per tick, not 2 per entity.

**Per block event (server thread, `native_authoritative`)**
`native_random_tick` `game.rs:1612`; `native_tick_block` `1628`; `native_update_shape` `1645`;
`native_neighbor_changed` `1401`; `native_block_changed` `1390`; `native_block_redstone` `1406`;
`native_analog_output` `1598`. Highest-frequency group in the game: tens to thousands per tick.
Wrappers: `native_hooks.rs:1229` (block changed), `1274` (redstone), `1363` (neighbor),
`1604` (analog), `1625` (random tick), `1658` (shape).

**Per packet**
`native_client_packet` on every inbound play packet `remote.rs:2189,2219,3585`.
Outbound `native_server_packet` is behind `WATCHED` (`lan/conn.rs:461`) — one relaxed load when off.

**Per chunk:** `native_chunk_load`/`_unload` `native_hooks.rs:8462,8471`, `native_chunk_generate`
`entry.rs:107`. **Startup:** `entry.rs:65–230` (function-pointer installs) + registration hooks
`game.rs:17643–17645`.

## 3. The empty-mod fast path: there isn't one (in dispatch)

`crates/horizon-client/src/mod_api.rs:860–935`:

```rust
pub(crate) static MODS: OnceLock<Mods> = OnceLock::new();
pub fn mods() -> &'static [Box<dyn Hooks>] {
    MODS.get().map_or(&[], |mods| mods.as_ref())          // acquire load + branch
}
fn is_off(index: usize) -> bool { … flag.load(Relaxed) } // per mod, per dispatch
fn entered<'a>(mods: &'a [Box<dyn Hooks>], hook: &'static str) -> Entered<'a> {
    Entered { first: place_in(self::mods(), mods), … }   // ptr-range arithmetic
}
```

Generated body (`mod_api_generated.rs:4636`, typified):

```rust
pub fn dispatch_player_tick(host: &mut dyn Host, mods: &[Box<dyn Hooks>]) {
    let mut event = PlayerTickEvent {  };                 // built unconditionally
    for mod_hook in super::entered(mods, "player_tick") { mod_hook.player_tick(host, &mut event); }
}
```

So with zero mods each dispatch pays: `OnceLock` acquire load, `place_in` pointer range check, an
`Entered` iterator, one `next()` that returns `None`, plus the event-struct store (and the
`*out = event.out` write-back for `replace`/`cancel` contracts). **No locks, no allocation, no
`format!`, no clone, no `dyn` call** on that path — `enter_native_mod`'s thread-local is only
touched inside `Entered::next`, which never runs with an empty list. `mods()` is a single atomic
load, so an extra `any_mods` atomic would buy nothing.

Cheap-path bypasses that do exist are ad hoc, at 40 call sites: `names.rs:224`, `item_draw.rs:30`,
`native_entities.rs:473`, `creatures.rs:7501,3586`, `natural_spawning.rs:458`, `machines.rs:995`,
`native_world_draw.rs:130`, `lan_stations.rs:85`. Everything else dispatches.

## 4. Overhead with zero mods

Model: empty dispatch = 3–8 ns once inlined (thin LTO, `codegen-units = 1`); the 841 KB of
generated source and the 15 ns of TLS work only matter once a mod exists.

**Per frame (zero mods)**, desktop scene, 60 visible entities:
- 46 fixed dispatches × ~6 ns ≈ 0.3 µs
- `native_mob_submit` path per visible mob: `NativeMobRender::of` (incl. `anim::state`),
  `mob_pose` matrix, `BlockEntityDraw::posed` — and `posed` does **`poses: vec![pose]`: one heap
  allocation per mob per frame** (`native_block_entity_draw.rs:153`), ~120–200 ns/mob
- 1 more dispatch per mob (`player_render_listened`), 1 per entity (`entity_outline`)
Total ≈ **10–15 µs/frame at 60 entities (0.12–0.18 % of 8.3 ms)**, ~35 µs at 200 entities (0.4 %).

**Per tick (zero mods)**, single player (authoritative): 13 fixed dispatches + `tick_mod_container_viewers`
allocating a `HashMap` every tick (`native_hooks.rs:11846`) ≈ 1.1 µs; block events at 300/tick ×
8 ns ≈ 2.4 µs → **~3.5 µs/tick, 0.007 % of a 50 ms tick**. A 10k-events/tick redstone build reaches
~0.16 % of the tick.

**With one trivial mod:** every dispatch adds two `thread_local` `Cell` writes
(`crash.rs:40`, guarded by `enter_native_mod`), one `is_off` atomic load and one vtable call ≈
15–30 ns. At 46 fixed + 2/mob ≈ 3–5 µs/frame. The real cliff is not the dispatch: any installed mod
turns off the entity-culling precheck (`creatures.rs:7501` requires `mods().is_empty()`), takes the
`hooks=true` name-tag path (a `String::new()` per unnamed mob per frame, `names.rs:250`), and, if it
touches `entity_tick_*`, switches on per-entity `Arc` clones and `Vec` pushes.

## 5. Verdict

**Runtime: not worth deleting.** Zero-mod overhead is ~0.1–0.5 % of frame time in dense scenes and
<0.02 % of the server tick; it is below run-to-run noise on most machines. The single non-trivial
item (`native_mob_submit` and `tick_mod_container_viewers`) is a 10-line fast-path fix, not a reason
to remove 37.5k lines. Deleting the API would also delete the *opt-out speedups* it enables
(`entity_culling_precheck`), i.e. it can make dense scenes **slower**.

**Build time and size: a real, large win.** Measured: the generator `syn`-parses 466 files /
305,788 lines on every `horizon-client` build — documented as ~1.5 s optimized, ~6 s unoptimized
(`docs/lite/reports/infra.md:234`, `Cargo.toml:78`). Deletion removes 840 KB of generated Rust,
13.4k lines of wrappers, 37.5k lines of shims, and the 507-method `Hooks` / 429-method `Host`
traits from the crate that is already "a third of the build" (`docs/build-times.md:121`: 60 s of a
107 s cold dev build; 10.6–14.4 s for a one-line `game.rs` edit). Expected saving: **several
seconds per incremental rebuild and 15–30 % of the `horizon-client` cold compile**, plus ~0.3–0.8
MiB of release `.text` and the whole `horizon-mod-api-gen` build-script dependency. The repo's own
audit already calls this "the largest build-time lever" (`assets.md`, `PLAN.md:152`, `CUTS.tsv:27`).

So: **build-time and size win; runtime win only in the ~0.1–0.5 % sense, and risky.**

## 6. If you want the runtime anyway

Top sites, in order of value per edit:

| # | site | cost now | fix |
|---|---|---|---|
| 1 | `native_mob_draw.rs:105` `mod_mob_geometry` (`creatures.rs:7649`) | 1 alloc + anim + matrix per visible mob per frame | gate on a `mob_submit_listened` flag (same pattern as `player_render_listened`, `native_mob_draw.rs:132`) or `!mods().is_empty()` |
| 2 | `native_hooks.rs:11845` `tick_mod_container_viewers` | `HashMap` alloc + guest scan per tick | early `if mods().is_empty() { return; }` before the map |
| 3 | `remote.rs:2189,2219,3585` `native_client_packet` | 1 dispatch per inbound packet (thousands/s while streaming chunks) | gate on `!mods().is_empty()` |
| 4 | block-event wrappers `native_hooks.rs:1229,1274,1363,1604,1625,1658` | 1 dispatch per neighbor/block/random event | `#[inline]` + `if mods().is_empty() { return; }` |
| 5 | `glowing.rs:29` `entity_outline` (also per dropped item) | 1 dispatch per entity per frame | same one-liner |

**Cheapest global fix (1 line, 507 sites, zero call-site edits):** in
`crates/horizon-mod-api-gen/src/lib.rs:979–991`, wrap every generated body:

```rust
let body = format!("if {mod_list}.is_empty() {{ return; }} {body}", mod_list = mod_list);
```

before the `dispatch.push_str` at line 988. This is semantically identical (an empty list can never
alter `*out`), drops the event-struct construction and the call to `entered`, and lets LLVM delete
the event entirely at the call site. Estimated 5–20 ns saved per dispatch, ~0.05–0.3 % of frame
time in busy scenes — measurable only with a tracer, not worth a release on its own.

**Do not** add a separate `any_mods: AtomicBool`: `mods()` is already one acquire load on a
`OnceLock`, and a second flag would have to be kept in sync by `name_mods`/`set_mod_on`.

## 7. What this analysis cannot say

No `cargo build`, no `perf`, no in-game counters. The ns figures are instruction-count models; the
build-time split (15–30 % of the `horizon-client` compile) is inferred from the documented per-crate
times plus the volume of generated source, not from an A/B build. If a decision hinges on <0.5 %
frame time, it needs `cargo build --profile lite` plus `perf stat` on a mob-farm save; if it hinges
on build time, the numbers above are already decisive.
