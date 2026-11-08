# Horizon → Horizon Lite: cargo features, cfg gating, and a measured deletion plan

Scope: `/home/solenopsisbot/coding/mc/horizon-src` @ working tree (Minecraft Java 26.3 port).
Read-only analysis. No files in `horizon-src` were modified. No `cargo build` was run; `cargo tree
--offline` (manifest-only) was used for dependency measurements, `wc`/`grep`/Python for source.

**Environment note:** `rg` is not installed on this machine (`/usr/bin/rg` absent). Counts below were
produced with `grep -R` and a small Python scanner. Every command is given in both the `grep` form
that was actually run and the equivalent `rg` form, so the numbers can be re-derived on a machine
that has ripgrep.

Headline numbers:

| Metric | Value |
|---|---|
| Rust lines, `crates/` + `xtask/` + `launcher/` | 1,443,639 |
| Rust files, `crates/` + `xtask/` | 2,388 |
| `horizon-client` / `horizon-client-render` / `horizon-world` / `launcher` | 650,618 / 223,162 / 192,797 / 113,794 |
| Workspace members (root `Cargo.toml`) | 40 |
| Cargo features defined across the workspace | 41 names in 10 manifests (12 in `horizon-client`, incl. `default`) |
| `cfg(feature = …)` / `cfg!(feature = …)` sites, all `.rs` | **108** (103 attributes + 5 macros) in 26 files |
| `cfg!(feature = "horizon-extras")` sites | **4** (0 `#[cfg]` sites) |
| Crates in `horizon-client` normal graph, default | **294** |
| … with `--no-default-features --features audio,controllers` (horizon-plain build) | **279** |
| … with `--no-default-features` (server build) | **264** |
| Horizon-only code that is *unconditional* today | **≈ 38,000 lines** (whole files; table §5) |
| Realistic maximum removable with all cuts in this report | **≈ 279,000 lines (19.3%)**, including launcher, probes and tests |

**The single most important finding:** `horizon-extras` does not hide code. It is four `cfg!`
expressions (three runtime decisions and one boolean constant). Turning it off removes ~15 crates
(`horizon-friends` and its crypto) and **zero lines of Horizon-only source**: cosmetics, emotes,
the emote wheel, the Horizon Settings pages, the minimap, PvP HUD, Studio, agent control, the mod
browser and the official-server list are all compiled and linked in every build. A `lite` *feature*
cannot fix that; only deletion (or a large `cfg` conversion) can.

---

## 1. Feature matrix (every feature in the workspace)

Counted from `[features]` in every member manifest. "Sites" = number of `cfg`/`cfg!` expressions
that name the feature, not number of occurrences of the string.

### 1.1 The client-facing chain

| Feature | Crate | Default | Definition | What it actually gates | Sites |
|---|---|---|---|---|---|
| `audio` | `horizon-client` | **on** | `["horizon-client-render/audio", "horizon-client-lib/audio"]` | sound output (`cpal`, ALSA/CoreAudio/WASAPI) | 0 own (pass-through) |
| `controllers` | `horizon-client` | **on** | `["horizon-client-lib/controllers", "dep:gilrs", "dep:horizon-dualsense", "horizon-client-input/controllers"]` | gilrs pads, DualSense output, gamepad UI | 4 |
| `horizon-extras` | `horizon-client` | **on** | `["discord", "friends", "heartbeat"]` | only the four `cfg!` sites below | **4 (all `cfg!`)** |
| `discord` | `horizon-client` | via extras | `["horizon-client-lib/discord"]` | `discord_presence.rs`, `game/discord.rs` | 7 |
| `friends` | `horizon-client` | via extras | `["horizon-client-lib/friends", "dep:horizon-friends"]` | `game/friends.rs` / `friends_off.rs`, invite-code joins | 21 |
| `heartbeat` | `horizon-client` | via extras | `["horizon-client-lib/heartbeat"]` | `heartbeat.rs`, telemetry `live` | 3 |
| `rng-trace` | `horizon-client` | off | `["horizon-core/rng-trace", "horizon-client-lib/rng-trace"]` | mob-AI RNG call-site tracing | 4 |
| `system-allocator` | `horizon-client` | off | `[]` | `main.rs` global allocator choice | 1 |
| `alloc-census` | `horizon-client` | off | `["horizon-threads/alloc-census"]` | `CensusAllocator`, `horizon-ctl memory` | 2 |
| `windows-mimalloc` | `horizon-client` | off | `[]` | **nothing** (dead feature, 0 sites) | 0 |
| `windows-segment-heap` | `horizon-client` | off | `[]` | `build.rs` embeds a manifest (via `CARGO_FEATURE_…`) | 0 rs / 1 build |

### 1.2 `horizon-client-lib` (the `horizon-ctl` / probe crate)

| Feature | Default | Definition | Sites |
|---|---|---|---|
| `audio` | **on** | `["horizon-client-render/audio"]` | 0 |
| `controllers` | **on** | `["dep:gilrs", "dep:horizon-dualsense", "horizon-client-input/controllers"]` | 0 |
| `discord` | **on** | `[]` (presence code lives in the shared source) | 0 |
| `friends` | **on** | `["dep:horizon-friends"]` | 0 |
| `heartbeat` | **on** | `["horizon-telemetry/live"]` | 0 |
| `rng-trace` | off | `["horizon-core/rng-trace"]` | 0 |
| `windows-mimalloc` | off | `[]` | 0 |
| `windows-segment-heap` | off | `[]` | 0 |

**Trap:** `horizon-client` depends on `horizon-client-lib` with `default-features = false`, but
`horizon-client-lib` is also a *root package* (`-p horizon-client-lib --bin horizon-ctl`). As a
root its defaults re-enable audio + controllers + friends + heartbeat and unify into the shared
build. CI's `--no-default-features` command selects only `-p horizon-client`, so it does not see
this. A lite fork must set `horizon-client-lib`'s `default = []` (or always pass
`--no-default-features` when building `horizon-ctl`).

### 1.3 Lower crates

| Crate | Feature | Default | Gates | Sites |
|---|---|---|---|---|
| `horizon-client-render` | `audio` | off | `cpal`, device probing, `audio.rs` internals | **46** |
| `horizon-client-render` | `test-support` | off | fixture helpers in `assets.rs`, `sound_engine.rs` | 3 |
| `horizon-client-input` | `controllers` | off | `dep:horizon-dualsense`, adaptive triggers | 3 |
| `horizon-items` | `test-support` | off | `Items::for_tests`, `enchant::tests` | 3 |
| `horizon-core` | `rng-trace` | off | `random.rs` trace hooks | 2 |
| `horizon-threads` | `alloc-census` | off | `CensusAllocator` | 1 |
| `horizon-mods` | `index` | off (client + lib turn it **on**) | registry SHA-256, minisign, wasmparser, shader-api | 3 |
| `horizon-telemetry` | `upload` | **on** | `ureq` upload path | 1 |
| `horizon-telemetry` | `live` | **on** | `ureq` "I'm playing" ping | 3 |
| `horizon-mod-deps` | `mysql`, `redis`, `websocket`, `opus`, `quic`, `sqlite`, `yaml`, `gif`, `snappy`, `all` | off | manifest shim only: the crate is 2 lines and nothing depends on it | 0 |

`horizon-mod-registry` (excluded from the workspace) and `horizon-telemetry-server` (excluded) have
no features. `launcher` is a separate workspace and is not covered by the root feature graph.

### 1.4 Sites per crate (attributes vs `cfg!`)

| Crate | `#[cfg]` attrs | `cfg!` | Total |
|---|---|---|---|
| `horizon-client-render` | 49 | 0 | 49 |
| `horizon-client` | 39 | 4 | 43 |
| `horizon-telemetry` | 4 | 0 | 4 |
| `horizon-client-input` | 3 | 0 | 3 |
| `horizon-mods` | 3 | 0 | 3 |
| `horizon-items` | 3 | 0 | 3 |
| `horizon-protocol` | 2 | 0 | 2 (these are `target_feature = "aes"`, **not** cargo features) |
| `horizon-core` | 2 | 0 | 2 |
| `horizon-threads` | 0 | 1 | 1 |

Excluding the two `target_feature` sites: **108 cargo-feature sites**. By feature name (a single
`cfg(any(audio, test))` counts once): `audio` 46, `friends` 21, `discord` 7, `controllers` 7,
`test-support` 6, `rng-trace` 4, `horizon-extras` 4, `heartbeat` 3, `live` 3, `index` 3,
`alloc-census` 2, `system-allocator` 1, `upload` 1.

Commands actually run:

```sh
# every cfg line that names a cargo feature (the 3 grep hits that say target_feature are excluded)
grep -rn 'cfg.*feature = "' crates --include=*.rs | grep -v 'target_feature' | wc -l   # 108
grep -rn 'cfg.*feature = "horizon-extras"' crates --include=*.rs                       # 4 lines
grep -rn '#\[cfg.*horizon-extras' crates --include=*.rs                                # 0
grep -rn 'cfg.*feature = "' crates --include=*.rs | wc -l                              # 111 (3 are target_feature = "aes")
```

Equivalent ripgrep:

```sh
rg -n 'cfg[^\n]*feature = "' -g '*.rs' crates | grep -v target_feature | wc -l
rg -n 'cfg!\(feature = "horizon-extras"\)' crates -g '*.rs'
rg -n '#\[cfg[^]]*horizon-extras' crates -g '*.rs'
```

---

## 2. The gating pattern (what "off" actually means)

There are three distinct patterns, and only one of them reduces compile time.

### Pattern A — real `#[cfg]`, both variants compiled from the same tree

- **audio**: `crates/horizon-client-render/src/audio.rs` has `#[cfg(feature = "audio")]` on the
  real implementation and `#[cfg(not(feature = "audio"))]` stubs (`type Stream = Infallible`,
  `open_named` returns an error). 46 sites.
- **controllers**: `crates/horizon-client/src/game/pad.rs:101` gates `mod hardware`; the
  `#[cfg(not(feature = "controllers"))] mod hardware` stub at `pad.rs:133` provides the same
  `Pads`/`PadId`/`PadRouter` API for the server build.
- **friends**: `crates/horizon-client/src/game.rs:157` selects `game/friends.rs`; `game.rs:162`
  selects `#[path = "game/friends_off.rs"] mod friends`. `friends_off.rs` is a 32-line API-compatible
  stub (`friends_view()` returns `FriendsView::default()`), so every call site compiles in both
  configurations. `net.rs` has parallel `#[cfg(feature)]` / `#[cfg(not(feature))]` definitions of
  `FRIEND`, `is_invite`, `join_friend`, `shown_address` (7 negative sites).
- **discord / heartbeat**: whole modules gated on/off (`client_lib.rs:60`, `:79`), call sites gated
  with `#[cfg(feature = …)]` (`game.rs:16254`, `:17535`).
- **test-support**: `#[cfg(any(test, feature = "test-support"))]` — one body, two build modes.

### Pattern B — `cfg!` (both sides always compiled)

`horizon-extras` is **only** this, exactly four sites:

1. `crates/horizon-client/src/entry.rs:17` — `if !cfg!(feature = "horizon-extras") { HORIZON_EXTRAS.store(false) }`
2. `crates/horizon-client/src/game.rs:17632` — `if cfg!(feature = "horizon-extras") && let Err(e) = add_official_server(...)`
3. `crates/horizon-client/src/game.rs:17637` — same for `add_partner_servers`
4. `crates/horizon-client/src/game/cosmetics.rs:440` — `fn enabled() -> bool { cfg!(feature = "horizon-extras") && horizon_cosmetics::enabled() }`

The functions being guarded (`add_official_server`, `add_partner_servers`, all of
`horizon-cosmetics`, all of `options_ui`'s Horizon pages) are compiled unconditionally. `cfg!`
only folds to a constant at MIR/LLVM time; it cannot remove type-checking, monomorphisation or
linkage. `docs/forking.md` says this explicitly: "both sides compile in every build, so no stub has
to follow the code it replaces."

### Pattern C — no gate at all

Everything in §5. This is the majority of Horizon's own code.

### What the server build proves

`.github/workflows/ci.yml:104` runs
`cargo clippy -p horizon-client --all-targets --no-default-features -- -D warnings`, and
`.github/workflows/game-build.yml:329` builds the same graph. So the `#[cfg(not(feature))]` stubs
*do* stay compiling — that is the one good property of the current design. But tests only run the
default feature set (`ci.yml:112`), so the stubs are type-checked, not exercised.

**Lite implication:** any `lite` boolean must reuse this machinery (stub modules per disabled
subsystem) or it will not compile. Converting the four `cfg!` sites to `#[cfg]` is not enough —
the call sites and the `options_ui` pages need stubs, and the `cosmetics` module is referenced from
9 files (`mobs/anim.rs`, `mobs.rs`, `names.rs`, `perspective.rs`, `creatures.rs`, `play_keys.rs`,
`game/cosmetics.rs`, `render/extras.rs`, `render/tab_list.rs`).

---

## 3. Optional external dependencies: who needs them, what dropping breaks

Crate deltas measured with
`cargo tree -p horizon-client --offline --edges normal --prefix none | sed 's/ (\*)$//' | sort -u | comm`.

| Dependency | Declared by | Enabled by | Adds (measured) | Drop for lite? | What breaks |
|---|---|---|---|---|---|
| `gilrs` 0.11 | client, client-lib (optional) | `controllers` | 15 crates: `gilrs`, `gilrs-core`, `hidapi`, `libudev-sys`, `inotify`, `inotify-sys`, `nix`, `uuid`, `vec_map`, `fnv`, `alsa*`, `cpal`, `dasp_sample` | **yes** | physical controllers; `horizon-ctl pad` virtual pad survives (stub at `game/pad.rs:133`) |
| `horizon-dualsense` | client, client-lib, client-input (optional) | `controllers` | (`hidapi`, `cpal` shared with above) | **yes** | rumble, adaptive triggers, lightbar; `gamepad.rs:1491` trigger effects |
| `cpal` 0.16 | render (optional), dualsense | `audio` or `controllers` | 4 on its own: `cpal`, `alsa`, `alsa-sys`, `dasp_sample` | **yes** if no sound | all sound output; `audio.rs` already has an `Infallible` stream stub |
| `ureq` 2 (rustls) | client, client-lib, render, cosmetics, server-files, telemetry, server | always (except telemetry `default-features=false`) | rustls, ring, webpki-roots, rustls-pki-types… ≈ 10 | **only for an offline build** | Microsoft login (`render/auth.rs:194`), skins (`skins.rs:1198`), pack browser (`pack_browser.rs:473`), Bluemap (`bluemap.rs:1166`), Realms, mod registry, cosmetics feed, telemetry, server pack download |
| `wgpu` `gles` | render (non-macOS target) | always on Linux/Windows | 4 crates: `glow`, `glutin_wgl_sys`, `khronos-egl`, `khronos_api` | **yes** if Vulkan is mandatory | GPUs/drivers with no Vulkan; the `--graphics-api gles` fallback |
| `wgpu` `dx12` | client, render (Windows target) | always on Windows | `windows` feature set + `gpu-allocator/d3d12` | **yes** if Vulkan on Windows is acceptable | DirectX 12 backend and its tests; `hlsl-out` translation tests |
| `objc2`, `objc2-app-kit`, `objc2-foundation` | client, client-lib (macOS), narrator | always on macOS | already in winit/wgpu tree | **partly** | splitscreen above-menu-bar (`game/split/windows.rs`); narrator needs `objc2-app-kit` for `NSSpeechSynthesizer` — keep narrator or rewrite it |
| `winresource` 0.1 | client `[build-dependencies]` | always, all hosts | `winresource` (0.8 MB rlib) | **yes** | Windows `.exe` icon + optional Segment Heap manifest; a missing icon panics on Windows, a windres-unusable path warns locally and panics in CI |
| `naga` 30 (direct) | client, client-lib, render, shader-api, shaders | always | already via wgpu | **trim features** | `glsl-in` only shader packs; `hlsl-out` only the DX12-translation tests; `msl-out`/`spv-out` only dev-deps. Keep `wgsl-in`; move the rest to `[dev-dependencies]` |
| `zip` 9 | render, client, mods, shaders, prepare, port-pack, server… | always | already | **keep** | resource packs are `.zip`; `render/zip.rs` is the reader. Only mods/shader paths can go |
| `flate2` 1.1 (`zlib-rs`) | world, protocol, render, client, launcher | always | pure-Rust zlib-rs | **keep** | region files, packet compression, pack decompression, log gzip |
| `miniz_oxide` 0.8 | client, client-lib, render | always | already | **yes, after 2 edits** | only `render/zip.rs:403,641,690` and `render/packs/cache.rs:619` recompress deflate; `flate2` already does deflate in pure Rust, so this is a duplicate codec |
| `mimalloc` / `libmimalloc-sys` (patched) | `horizon-threads` | always | `cc` C build + patched crate | **yes** (`system-allocator` already exists) | allocator performance; removes the `[patch.crates-io] libmimalloc-sys` and `third_party/libmimalloc-sys` maintenance |
| `symphonia` | render | **always** (not behind `audio`; see note) | 6 crates | **with audio** | OGG/Vorbis music and sounds |
| `image-webp`, `zune-jpeg` | render | always | 5 crates | **with the pack/mod browser** | WebP/JPEG pack icons (`pack_screen.rs:106`, `hud.rs:203,228`) |
| `lz4_flex` | render, world | always | already | **keep** | HUD pixel compression, region section compression |
| `rusqlite`/`mysql`/`quinn`/… | `horizon-mod-deps` | off | 0 by default | **delete crate** | nothing in the game graph depends on it |

> Note: `symphonia` is **not** behind `audio` in `horizon-client-render/Cargo.toml` — it is an
> unconditional dependency. Dropping sound does not drop the Vorbis decoder. That is a free cut
> for a no-audio lite build.

**Measured feature deltas** (`cargo tree … | wc -l` after dedup):

```text
no-default-features                     264 crates
no-default + audio                      268  (+4)
no-default + controllers                279  (+15)
no-default + friends                    279  (+15)
no-default + discord / heartbeat        264  (+0; ureq is already unconditional)
default (audio+controllers+extras)      294  (+30)
```

So the entire `horizon-extras` feature is worth **15 crates**, all of them `horizon-friends`' crypto
(`spake2`, `chacha20poly1305`, `curve25519-dalek`, `hkdf`, `hmac`, `poly1305`, `if-addrs`, `socket2`, …).

---

## 4. `lite` feature strategy: (a) one feature, (b) profile crate, (c) deletion

### Option (a) — one `lite` cargo feature that turns everything off

**Does not work as a subtractive switch.** Cargo features are additive and `default` cannot be
un-enabled by another feature. To make `lite` mean anything you must:

1. flip the default set (`default = []` or `default = ["lite"]`),
2. wrap every extra in `#[cfg(feature = "lite")]` **positive** gates (or `not(lite)` around
   defaults), and
3. add a stub for every item the rest of the crate still names.

That is ~38k lines × two configurations. Cost: all 108 existing sites become a 2×N matrix; the
`horizon-plain`/server build is a third configuration. `--all-features` becomes unbuildable (both
sides of every `not`), and any dependency or launcher that enables `horizon-extras` silently
re-enables it (feature unification). This is the classic negative-feature anti-pattern. Compile
time improves only for the code you actually wrap in `#[cfg]`; `cfg!` gains nothing.

### Option (b) — a `horizon-lite` profile crate

```toml
[dependencies]
horizon-client = { path = "../horizon-client", default-features = false, features = ["audio"] }
```

This is exactly today's `horizon-plain` build: **279 crates instead of 294, 0 lines less code,
identical binary except the four `cfg!` branches**. It cannot express "no cosmetics", "no mods",
"no Horizon Settings" because those are unconditional. It is useful only as a thin `main`/packaging
crate, not as a stripping mechanism. It also adds a second binary and a second place to keep
`entry::main` arguments in sync.

### Option (c) — actual deletion (recommended for a fork)

`docs/forking.md` already tells forks to do this: "To remove an extra for good, delete its files from
the table and the lines its gate guards." A fork does not need to keep upstream's feature matrix;
it needs a small, honest tree.

| | (a) `lite` feature | (b) profile crate | (c) delete |
|---|---|---|---|
| LOC compiled | unchanged (`cfg!`) or 2× matrix | unchanged | −38k extras, up to −279k total |
| Cold build | small if `#[cfg]` conversion done; big diff | no change | **real**: fewer crates and fewer rustc units |
| Incremental build | `game.rs` still recompiles all extras | no change | smaller `horizon-client` unit (the 21 s/35 s tail in `docs/build-times.md`) |
| Binary size | only reachable `cfg`-removed code | no change | crate drops + unreachable code; cosmetic/HUD code runs every frame today, so it is linked |
| Upstream sync | every upstream cfg change conflicts | trivial (manifest only) | merge conflicts in deleted files; `git rerere` + a keep-list helps; sync by rebasing quarterly |
| Risk | silent feature re-enable; unbuildable `--all-features` | none, but no benefit | one-time surgery, each commit green |
| Maintenance | permanent 2× test matrix | one more crate | deleted code cannot rot |

**Recommendation:** (c), in small commits, with a *marker* feature only if CI needs to name the
configuration. Keep the marker inert:

```toml
[features]
default = ["audio"]
lite = []          # documentation/CI marker only; never used in cfg
```

Do **not** put `#[cfg(feature = "lite")]` in the tree. If a conditional build must survive (e.g.
the dedicated server), keep the existing positive `#[cfg(feature = "server")]` pattern and delete
the client surface instead.

**Target configuration for Horizon Lite (single-player first):** default features `["audio"]`
(controllers optional), no `horizon-extras`, no discord/friends/heartbeat, no mods runtime, no
dedicated server, no Realms, no shader packs, no native mod API, Vulkan/Metal only, system allocator.
That is the `264 + 4 = 268`-crate graph before further crate deletion, and about 1.16M lines after
the cuts below (still a Minecraft port; see §9).

---

## 5. What is gated today vs what is unconditional: top 20

All whole-file counts are `wc -l`. "Gate today" means the gate on the *module declaration or the
only entry point*; "none" means the file is compiled and reachable in every build.

| # | File | LOC | Gate today | Delete coupling |
|---|---|---|---|---|
| 1 | `crates/horizon-client-render/src/options_ui.rs` | 8,402 (partial) | none; `HORIZON_EXTRAS` only swaps 2 main-menu rows (`:3136-3158`) | Horizon pages (`Horizon`, `Extras`, `Pvp`, `Studio`, `Agent`, `Split*`, `Music`, `Mods`, `ModBrowser`, `Shader*`, `Graphics`, `Controller`) share the file with vanilla pages; needs extraction, not `rm` |
| 2 | `crates/horizon-mods/` (crate) | 6,924 | none; `index` only adds registry checks | `game/mods.rs`, `mod_content.rs`, `mod_registry.rs`, `render/mod_browser.rs`, `mod_list.rs`, launcher |
| 3 | `crates/horizon-cosmetics/` (crate) | 6,343 | none; `cfg!` only in `game/cosmetics.rs:440` | `mobs/anim.rs` (6 refs), `mobs.rs:1574`, `names.rs:768`, `render/extras.rs`, `tab_list.rs` |
| 4 | `crates/horizon-client/src/mod_content.rs` | 2,927 | none | `game/mods.rs`, `client_lib.rs:97`, launcher, `mod_content_tests.rs` (4,787) |
| 5 | `crates/horizon-client/src/game/agent.rs` | 2,264 | none (`mod agent;` `game.rs:54`) | `agent_settings.rs`, `game/control.rs`, `control.rs`, `horizon-ctl` |
| 6 | `crates/horizon-client-render/src/pvp.rs` | 1,835 | none (`pub mod pvp;`) | `pvp_hud.rs`, `graphics_ui.rs`, `options_ui.rs` `Page::Pvp` |
| 7 | `crates/horizon-client-render/src/extras.rs` | 1,257 | none (`pub mod extras;`) | `extras_ui.rs`, `options_ui.rs` `Page::Extras`, `horizon_cosmetics::prefs` |
| 8 | `crates/horizon-client/src/game/cosmetics.rs` | 1,180 | `cfg!` in `enabled()` only | `game/cosmetics/fx.rs`, `Game::cosmetics` field, `scoreboard.rs:830` |
| 9 | `crates/horizon-client/src/game/mods.rs` | 997 | none | `mod_content`, `mod_registry`, `mods` UI, native mod hotload |
| 10 | `crates/horizon-client/src/game/studio.rs` (+ `src/studio/` 2,981) | 950 | none | `game.rs:3110-3119,9538,9749`, `net.rs` recorder |
| 11 | `crates/horizon-client-render/src/pvp_hud.rs` | 792 | none | `hud.rs`, `pvp.rs` |
| 12 | `crates/horizon-client/src/game/pvp.rs` | 764 | none | `game.rs:3045,7878,7973`, `settings.extras.pvp` |
| 13 | `crates/horizon-client-render/src/minimap.rs` | 682 | none | `extras.rs` (`minimap_shown`, `minimap_wanted`), `graphics_ui` |
| 14 | `crates/horizon-client/src/game/tweaks.rs` | 545 | none | `game.rs:2487` (`tweaks::Tweaks`), mouse handling |
| 15 | `crates/horizon-client/src/friends_screen.rs` | 340 | **none even with `friends` off** (the `_off` stub returns `FriendsView::default()`) | pause menu, `game/friends_off.rs` |
| 16 | `crates/horizon-client/src/mod_registry.rs` | 334 | none | `mod_content`, pack browser, `ureq` |
| 17 | `crates/horizon-client/src/game/cosmetics/fx.rs` | 321 | none | `game/cosmetics.rs` |
| 18 | `crates/horizon-client-render/src/extras_ui.rs` | 268 | none (`pub(crate) mod`) | `options_ui.rs`, `horizon_cosmetics::prefs` |
| 19 | `crates/horizon-client/src/game/emotes.rs` | 228 | none | `mobs.rs:1574` `emote` field, `mobs/anim.rs` |
| 20 | `crates/horizon-client/src/game/emote_wheel.rs` | 216 | none | `game.rs:2960`, `play_keys.rs:151` |

Next five: `game/extras.rs` (283), `agent_settings.rs` (255), `render/mod_list.rs` (220),
`render/mod_browser.rs` (189), `extras_hud.rs` (143). Plus `multiplayer.rs:364-469` (the official
and partner server block, ~106 lines, guarded only by the two `cfg!` call sites) and
`options_ui.rs`'s `HORIZON_EXTRAS` static (`:27`).

Whole-file total: **16,433 lines** in the two big crates + **13,267** in `horizon-cosmetics` and
`horizon-mods` = **≈29,700**. Adding agent/control (5,637) and `src/studio` (2,981) puts the
unconditional Horizon surface at **≈38,000 lines**. None of it disappears with
`--no-default-features`.

### What *is* hidden today

| Surface | Gate | LOC hidden |
|---|---|---|
| Discord presence | `#[cfg(feature = "discord")]` (7 sites) | 623 + 47 |
| Play with Friends host | `#[cfg(feature = "friends")]` + 32-line stub | 334, but `friends_screen.rs` (340) stays |
| Heartbeat | `#[cfg(feature = "heartbeat")]` (3) | 74 |
| Audio backend | `#[cfg(feature = "audio")]` (46) | cpal paths, not the mixer |
| Controller hardware | `#[cfg(feature = "controllers")]` + stub | 15 crates, not the pad UI |

---

## 6. Build-time steps a lite fork must keep (and the traps)

### 6.1 `horizon-mod-api-gen` — the big one

`crates/horizon-client/build.rs` and `crates/horizon-client-render/build.rs` both call
`horizon_mod_api_gen::generate(root, OUT_DIR, Target::Client|Render)` on **every** build of those
crates.

Inputs it hard-requires (any missing file is a build failure, not a warning):

- `native-hooks.json` (152 KB, **432 hooks**, **177 helpers**)
- `tools/native-hook-fragments/*.json` (160 files, **78 more hooks**; 510 unique after dedup)
- `crates/horizon-client/src/game/native_hooks.rs` (**13,391 lines**, 639 `fn native_`)
- `crates/horizon-client/src/mod_api.rs`
- every file under `crates/horizon-client/src/game/` (parsed with `syn` to build the host API)
- 17 free-function hook targets, e.g. `horizon_client_lib::menu`, `horizon_client_lib::crafting`,
  `horizon_client_lib::breathing`, `horizon_client_lib::motion`, `horizon_client_lib::landing`,
  `horizon_client_lib::hunger`, `horizon_client_lib::lan::hub::chat`,
  `horizon_world::loot`, `horizon_world::item_defaults`,
  `horizon_client_render::gfx::native_render`

Generated output (measured in `target/debug/build/horizon-client-*/out/`):
`mod_api_generated.rs` 598,840 B, `mod_api_generated_host.rs` 194,821 B,
`mod_api_host_generated.rs` 46,910 B, `native_render_generated.rs` 1,873 B. Included at
`mod_api.rs:979,1062`, `game/mod_api_host.rs:149`, `gfx/native_render.rs:15`.

**Traps:**
- Deleting any of the 24 helper modules (`native_server`, `native_client_services`,
  `native_entity_refs`, `native_entity_motion`, `native_level_refs`, `machines`, …) fails the
  generator with `"<path>: No such file"`.
- Deleting a hook function fails with `"missing native_<name>"`; leaving a placeholder body fails
  with `"the let _ = (…); placeholder needs its dispatch call; run cargo run -p xtask -- mod-api"`.
- The generator `rerun-if-changed`s the whole `game/` directory, `native-hooks.json` and each
  external target file. Deleting a file triggers a full regeneration — correct, but it means the
  build script is not removable while any hook remains.
- `[profile.dev.package.horizon-mod-api-gen] opt-level = 3` plus `syn`/`proc-macro2` overrides in
  the root `Cargo.toml` exist solely for this generator (~6 s unoptimized vs ~1.5 s optimized per
  the manifest comment). If the generator goes, remove those four profile blocks too.

**Verdict:** keep it for lite v1. Removing the native mod API is a separate, last, high-risk
project (§8, C12): it touches 432 dispatch sites, 13.4k lines of `native_hooks.rs`, the render
generator and `horizon-mods::api_level::MARK` in `crates/horizon-client/src/main.rs:12`.

### 6.2 `winresource` and the icon

`horizon-client/build.rs` embeds `packaging/icons/horizon.ico` and, under
`windows-segment-heap`, `windows-segment-heap.manifest`. A missing icon panics on Windows
(`canonicalize` in `resource_path`); a path windres cannot handle (spaces/non-ASCII, no 8.3 alias)
warns in a local build and **panics in CI** (`if CI.is_none()`). Deleting `packaging/` therefore
breaks Windows builds. `winresource` is a build-dependency on *all* hosts even though it is only
used in `#[cfg(windows)]` — drop the dependency and the whole block for lite.

### 6.3 Other build scripts

- `horizon-world/build.rs` hashes `horizon-world/src`, `horizon-core/src`, both manifests,
  `Cargo.lock`, profile and target into `HORIZON_WORLD_SOURCES`. Any dependency change (all of §7)
  invalidates the prepared behaviour/registry snapshot cache. Not a failure; expect a slower first
  run after each commit, and do not "fix" it by deleting the hash.
- `horizon-prepare/build.rs` hashes its own sources into `HORIZON_PREPARE_SOURCES_SHA256`; the
  launcher compares it with a version folder. If the launcher is deleted this is irrelevant; if
  kept, keep `horizon_prepare::sources_sha256` in sync.
- `launcher/build.rs` does the same icon embedding for the launcher.
- There is **no protobuf/proto codegen** in this tree. `horizon-protocol` is hand-written Rust
  (no `prost`/`protox` in any manifest). The "proto codegen" task item does not apply.

### 6.4 Cargo-level traps

- `autobins/autoexamples/autotests = false` in `horizon-client` and `horizon-client-lib`; every
  `[[test]]`/`[[example]]`/`[[bin]]` is explicit. Deleting a test/example file without deleting
  its manifest entry breaks `cargo test/clippy --all-targets`.
- `horizon-client-lib`'s `[lib] path = "../horizon-client/src/client_lib.rs"` and all its
  `[[example]]`/`[[test]]` paths point into `horizon-client`. Deleting `crates/horizon-client/src/`
  or its `tests/` breaks the lib package too.
- Feature forward references must be deleted in the same commit:
  `horizon-client`'s `friends = ["horizon-client-lib/friends", …]` etc. Cargo errors with
  `"feature … does not exist"` if only one side is edited.
- Dev-dependency feature unification: `horizon-client` dev-depends on
  `horizon-client-render` with `features = ["test-support"]` and on `horizon-items` with
  `test-support`. Deleting those features requires editing the dev-deps in the same commit.
- `horizon-optifine` **dev-depends on `horizon-bench`** (`crates/horizon-optifine/Cargo.toml:16`).
  Dropping `horizon-bench` breaks `cargo test -p horizon-optifine` even though the game never
  uses it.
- `[patch.crates-io]` for `wgpu-hal`, `naga`, `libmimalloc-sys`: dropping mimalloc requires
  deleting the patch *and* `third_party/libmimalloc-sys`, or `cargo` keeps the path dependency.
- `-D warnings` in CI: after removing callers, private helpers become `dead_code` errors. The tree
  already uses `#[cfg_attr(not(feature = "audio"), allow(dead_code))]` (audio.rs:663) and
  `(not(feature = "controllers"))` (pad.rs:120); deleted subsystems need the same treatment during
  the transition, then the attributes go with the code.
- `cargo clippy --workspace --all-targets` still builds all 40 members. Trim `members` in the root
  `Cargo.toml` or CI keeps compiling `horizon-bots`, `horizon-polytone`, etc.
- Python tools hardcode paths (`tools/build_times.py:62`, every `tools/test_*_parity.py`,
  `tools/stamp_native_hooks.py`, `tools/pr_ready.py:80`). Deleting files breaks
  `python3 -m unittest discover -s tests` and parity selection; update/remove them in the same
  commit as the code.

### 6.5 Build steps that must stay

| Step | Why |
|---|---|
| `horizon-mod-api-gen` (client + render) | generated traits are `include!`d and called by gameplay; **unless** the mod API is removed |
| `native-hooks.json` + `tools/native-hook-fragments/` | hard input to the generator |
| `horizon-world/build.rs` | cache key correctness, not optional |
| `horizon-prepare/build.rs` | only if the launcher/prepare remains |
| `horizon-theme` generated `tokens.css` | `xtask tokens`; a theme test fails if stale (launcher/UI) |
| `zip`/`flate2` | resource packs and region files — vanilla features, not extras |

---

## 7. Architecture: cycles, rules, and cross-crate cut edges

No Cargo dependency cycles exist. The layering is a DAG, but there are three hidden edges that
make naive cuts fail.

### 7.1 The DAG (workspace dependencies only)

```
horizon-core  (leaf)
  └── horizon-world                    (only horizon-core: Cargo.toml:16)
        ├── horizon-client-core        (Cargo.toml:10; uses horizon_world::nbt in gamerules.rs:4, component.rs:4)
        ├── horizon-protocol           (core + world)
        ├── horizon-command            (client-core + core + protocol + world)
        ├── horizon-items              (client-core + core + world)
        └── horizon-client-core ──► horizon-client-input (client-core + theme)
horizon-cosmetics, horizon-friends, horizon-narrator, horizon-telemetry, horizon-shader-api,
horizon-hdr, horizon-threads, horizon-theme, horizon-dualsense  (leaves)
  └── horizon-telemetry ──► horizon-bench
  └── horizon-friends   ──► horizon-relay
  └── horizon-shader-api ─► horizon-mods
horizon-client-render  (cosmetics, assets, bench, client-core, client-input, command, core, hdr,
                        items, narrator, optifine, protocol, shader-api, shaders, telemetry,
                        theme, threads, world)          ← no horizon-client edge
horizon-client-lib     (everything above; source lives in horizon-client/src/client_lib.rs)
horizon-client         (horizon-client-lib + the same set + winit/wgpu)
```

**"Does `horizon-client-render` avoid gameplay?"** Yes at the Cargo level: it has no
`horizon-client` dependency and no `crate::game` import (the only `game` matches are a test string
in `crash.rs:748,780` and `telemetry.rs:432`). But it is **not** gameplay-free in the wider sense:
it depends on `horizon-items`, `horizon-world`, `horizon-cosmetics`, `horizon-narrator`,
`horizon-telemetry` and `horizon-bench` (`crates/horizon-client-render/Cargo.toml:10-32`), and it
re-exports item modules (`render/lib.rs:158-164`) and `horizon_world::json_folder` (`lib.rs:63`).
A cut in any of those forces edits in render.

**"Does `horizon-world` depend only on `horizon-core`?"** Yes — `crates/horizon-world/Cargo.toml`
lists only `horizon-core` among workspace crates. It also has `libm`, `serde`, `sha2`, `postcard`,
`flate2`, `lz4_flex`, `xxhash-rust`.

### 7.2 Hidden edge 1: render's build script reads the client's sources

`crates/horizon-client-render/build.rs` → `horizon-mod-api-gen::generate(..., Target::Render)` →
`src/build.rs::track()` always `rerun-if-changed`s `native-hooks.json`, `mod_api.rs`,
`tools/native-hook-fragments/`, `game/native_hooks.rs`, and every external hook target. The crate
graph has no render→client edge, but **deleting `crates/horizon-client/src/game/native_hooks.rs`
breaks `horizon-client-render`**. This is the single most surprising build coupling in the tree.

### 7.3 Hidden edge 2: single player *is* a server (do not delete `lan/`)

`crates/horizon-client/src/game/integrated.rs:22` imports
`horizon_client::lan::{Lan, MAX_PLAYERS, NetConfig, OwnerProfile, hub::HubConfig}`; the integrated
server hosts the world on a Server thread and the window joins it *through the LAN hub*. Therefore:

- `crates/horizon-client/src/lan/` (37,718 lines, `hub.rs` alone 6,496) is **required for single
  player**. "Single-player-first" is not "no server code".
- `horizon-anticheat` is used by `crates/horizon-client/src/lan/anticheat.rs:9` and
  `lan/prediction.rs:24`; `horizon-chat-filter` by `lan/hub/chat_filter.rs:6`. They compile into
  the client and cannot be dropped without refactoring the hub.
- `horizon-server-files` is used outside the dedicated server: `control.rs:128` (`private_file`),
  `game/tempban.rs:13`, `game/chat_filter.rs:11`, `game/remote.rs:1100` (`profiles`).

Only the **dedicated** entry point (`game/dedicated.rs` + `game/dedicated/`, 5,088 lines) and the
`horizon-server` supervisor crate (19,769) are removable without touching single player.

### 7.4 Hidden edge 3: `horizon-client-lib` shares the client's source tree

`crates/horizon-client-lib/Cargo.toml`: `[lib] path = "../horizon-client/src/client_lib.rs"`,
127 `pub mod` declarations. `horizon-client`'s `lib.rs` is a re-export only. Consequences:

- Deleting `horizon-client-lib` means turning `client_lib.rs` into `horizon-client`'s lib root and
  merging two manifests (dependency sets are nearly identical), plus moving every `[[bin]]`,
  `[[example]]`, `[[test]]` path.
- Any cut inside `mobs/`, `net.rs`, `save.rs`, `lan/` is a cut in **both** crates; there is no
  boundary to hide behind.
- `horizon-client` compiles gameplay **twice** for its executable tests (per `AGENTS.md`), which is
  a large test-build cost; a lite fork can drop the duplicate test target.

### 7.5 Concrete cut edges (file evidence)

| Cut | Forces edits in | Evidence |
|---|---|---|
| `horizon-cosmetics` | `horizon-client` mob rendering, `horizon-client-render` extras | `client/mobs/anim.rs:772,779,788,1135,1153,1157`; `client/mobs.rs:1574`; `client/game/names.rs:768`; `render/extras.rs:950,1021,1059`; `render/tab_list.rs`; `render/extras_ui.rs:194` |
| `horizon-telemetry` | multiplayer official server, crash reports, benchmarks | `multiplayer.rs:368-405` (`OFFICIAL_ADDRESS`, `OFFICIAL_PREVIOUS`); `render/crash.rs` 4 refs; `render/telemetry.rs` 9; `benchmark.rs` |
| `horizon-bench` | optifine tests, benchmark CLI, render telemetry, dedicated report | `crates/horizon-optifine/Cargo.toml:16`; `client/benchmark.rs:14`; `game/dedicated/report.rs`; `render/telemetry.rs` |
| `horizon-friends` | net.rs, pause menu, `horizon-ctl friends`, multiplayer screen | `net.rs:492-594`; `game.rs:157-162,3129,16989`; `multiplayer.rs:2296`; `game/native_client_services.rs:13-131`; `game/friends_off.rs` |
| `horizon-mod-api-gen` | both build.rs, `mod_api.rs`, 432 hook bodies, `main.rs` | `client/build.rs`; `render/build.rs`; `mod_api.rs:979,1062`; `game/mod_api_host.rs:149`; `gfx/native_render.rs:15`; `main.rs:12` (`horizon_mods::api_level::MARK`) |
| `horizon-shaders`/`-shader-api` | `gfx.rs` + `gfx/` (73k) | 314 `horizon_shaders` refs + 85 `horizon_shader_api` refs, e.g. `gfx.rs:5155,6900,7204,7409` |
| `horizon-narrator` | render widgets, options, screen narration | `render/widgets.rs:464`; 35 `horizon_narrator` refs |
| `wgpu` `gles`/`dx12` | render graphics backend selection | `crates/horizon-client-render/Cargo.toml` target sections; `render/graphics.rs` `graphicsApi` |
| `mimalloc` | `horizon-threads`, `main.rs`, workspace patch | `crates/horizon-threads/Cargo.toml`; `client/main.rs:4-9`; root `Cargo.toml [patch.crates-io]` |

No cut in `horizon-world`, `horizon-core`, `horizon-protocol`, `horizon-assets` is warranted: they
are the vanilla substrate.

---

## 8. Recommended deletion order (each step a green commit)

Mechanics: Cargo needs the *consumer* edited before the *provider* can be deleted, so in the
dependency DAG you edit top-down; the crate removal order that results is bottom-up. Each commit
below removes one subsystem's last reference and then deletes its files. Verification is
`cargo check -p … --lib --bins` while iterating; run `--all-targets` before committing (examples
are part of the tree and do reference extras).

Baseline before any cut (record it in the first commit message):

```sh
cargo check -p horizon-client --all-targets
cargo check -p horizon-client --no-default-features
cargo clippy -p horizon-client --all-targets -- -D warnings
cargo tree -p horizon-client --offline --edges normal --prefix none | sort -u | wc -l   # 294
```

| Commit | Deletes | Also edits | Verify | LOC |
|---|---|---|---|---|
| **C1** `lite: drop crates no game target uses` | `horizon-polytone` (0 consumers), `horizon-bots`, `horizon-port-pack`, `horizon-release-sign`, `horizon-server`, `cargo-horizon-mod`, `horizon-mod-deps`, `horizon-mod-registry`, `horizon-telemetry-server`; `launcher/` if no launcher | root `Cargo.toml members`, `xtask/src/main.rs` (TOOLS/package-server), `.github/workflows/*`, docs | `cargo check -p horizon-client -p horizon-client-lib --all-targets` | ≈51k (+114k if launcher) |
| **C2** `lite: system allocator` | `mimalloc`, `libmimalloc-sys`, `third_party/libmimalloc-sys`, `[patch.crates-io]` entry, `Allocator`/`CensusAllocator`, `system-allocator`/`alloc-census`/`windows-*` features, `horizon-ctl memory` heap tag | `horizon-threads`, `client/main.rs:4-9`, `game/memory.rs` | `cargo check -p horizon-client --all-targets`; run `--benchmark standard` before/after to measure the regression | ≈2k |
| **C3** `lite: drop the dedicated server` | `game/dedicated.rs`, `game/dedicated/` (5,088), `--dedicated`/`--transfers` CLI, `ExecutionRole::Dedicated`, `horizon-server-files` only if `control/tempban/chat_filter/profiles` are refactored (they are not, today) | `game.rs` arguments, `horizon-client-lib` bin, `xtask package-server` | `cargo check -p horizon-client --all-targets` | 5.1k |
| **C4** `lite: drop telemetry, heartbeat and benchmarks` | `horizon-telemetry`, `horizon-bench`, `heartbeat.rs`, `render/telemetry.rs`, `benchmark.rs`, crash upload, `HORIZON_TELEMETRY` paths | move `OFFICIAL_ADDRESS`/`OFFICIAL_PREVIOUS` into `multiplayer.rs`; `render/crash.rs`; `game/loading_window.rs`; `game/world_session.rs`; `game/repro.rs`; delete `--benchmark`/`--smoke-report` | `cargo check -p horizon-client -p horizon-client-lib --all-targets`; `cargo test -p horizon-optifine --lib` (bench dev-dep!) | 5.0k |
| **C5** `lite: drop Play with Friends` | `horizon-friends`, `horizon-relay`, `friends_screen.rs`, `game/friends.rs`, `game/friends_off.rs`, `friends` feature in both manifests, `net.rs` friend branches, `horizon-ctl friends` | `multiplayer.rs:2296`, `game.rs:157-162,3129,16989`, `native_client_services.rs:13-131`, pause menu, `game/screens.rs` | `cargo check -p horizon-client -p horizon-client-lib --all-targets`; then `--no-default-features` | 7.8k |
| **C6** `lite: drop cosmetics, emotes, emote wheel` | `horizon-cosmetics`, `game/cosmetics.rs`, `game/cosmetics/`, `game/emotes.rs`, `game/emote_wheel.rs`, `Game::cosmetics/emotes/emote_wheel` | `mobs/anim.rs`, `mobs.rs:1574`, `names.rs:768`, `perspective.rs`, `creatures.rs:7766`, `play_keys.rs:151`, `scoreboard.rs:830`, `render/extras.rs`, `tab_list.rs`, `extras_ui.rs` | `cargo check -p horizon-client-render --lib && cargo check -p horizon-client --all-targets` | 8.3k |
| **C7** `lite: drop Horizon Settings and extras UI` | `render/extras.rs`, `extras_ui.rs`, `client/game/extras.rs`, `tweaks.rs`, `extras_hud.rs`, `HORIZON_EXTRAS`, `entry.rs:17-21`, Horizon pages in `options_ui.rs`, `safe_mode`/extras file | `options_ui.rs` (extract vanilla pages), `game.rs` fields and `draw_extras`, `graphics_ui.rs`, `settings.rs` | `cargo check -p horizon-client-render --lib && cargo check -p horizon-client --all-targets` | ~7k (partial options_ui) |
| **C8** `lite: drop PvP HUD, minimap, Studio, agent control` | `render/pvp.rs`, `pvp_hud.rs`, `minimap.rs`, `client/game/pvp.rs`, `game/studio.rs`, `src/studio/`, `game/agent*.rs`, `game/control.rs`, `control.rs`, `game/events.rs`, `ui_control.rs`, `horizon-mcp`, `horizon-ctl` control commands | `game.rs` fields (`pvp`, `studio_*`, `control`, `frame_stats`), `net.rs` recorder, `hud.rs`, `graphics_ui.rs`, `options_ui.rs` pages | `cargo check -p horizon-client -p horizon-client-lib --all-targets`; `cargo test -p horizon-client-lib --bin horizon-ctl` | ≈13.4k |
| **C9** `lite: drop content mods and the registry` | `horizon-mods`, `mod_content.rs`, `mod_registry.rs`, `game/mods.rs`, `render/mod_browser.rs`, `mod_list.rs`, `index` feature, mods UI pages, `.hmod`/`.hpack` loaders | `client_lib.rs:97-98`, `game.rs` `mods::*` registration (many call sites), `packs.rs` content root, `main.rs` `MOD_API_LEVEL` (if native API also goes, C12) | `cargo check -p horizon-client -p horizon-client-lib --all-targets` | 11.6k |
| **C10** `lite: drop Realms` | `realms.rs` (6,098), `realms/` (2,511), Realms UI/pack upload | `client_lib.rs:120`, `title.rs`/multiplayer screen, `ureq` if offline | `cargo check -p horizon-client --all-targets` | 8.6k |
| **C11** `lite: drop shader packs` | `horizon-shaders` (23,773), `horizon-shader-api` (5,876), pack loader/screens/options, `naga` `glsl-in`/`hlsl-out` | `gfx.rs` + `gfx/` (73k; 486 "pack" references), `graphics_ui.rs`, `options_ui.rs`, `shader_pack_list.rs`, `shader_ui.rs`, `pack_post.rs` | `cargo check -p horizon-client-render --lib && cargo check -p horizon-client --all-targets` | 29.6k |
| **C12** `lite: drop the native mod API` | `horizon-mod-api-gen`, both `build.rs`, `native-hooks.json`, `tools/native-hook-fragments/` (160), `tools/stamp_native_hooks.py`, `mod_api.rs`, `game/native_hooks.rs` (13.4k), `game/mod_api_host.rs`, `game/native_client_services.rs`, `gfx/native_render.rs`, 432 `dispatch_*` bodies | every `game/` file with a hook (mechanically: remove `native_*` bodies and `mod_api::dispatch_*` calls), `main.rs:12`, `xtask mod-api`, root profile overrides | `cargo check -p horizon-client -p horizon-client-render -p horizon-client-lib --all-targets`; `cargo test -p horizon-mod-api-gen` gone | 18.9k + 600 KB generated |
| **C13** `lite: trim renderer backends and build deps` | `wgpu` `gles`, `dx12` (if Vulkan-only), `objc2*` splitscreen paths, `winresource`, icon/manifest block, `miniz_oxide`, `symphonia` (already unconditional!), `image-webp`/`zune-jpeg` if no downloaded packs, `naga` features to `wgsl-in` (rest dev-only) | `render/Cargo.toml` target sections, `graphics.rs` `graphicsApi`, `split/windows.rs`, `build.rs`, `zip.rs:403…`, `packs/cache.rs:619` | per host: `cargo check -p horizon-client-render`; Windows: `cargo check --target x86_64-pc-windows-msvc -p horizon-client` | ~1k + deps |
| **C14** `lite: trim workspace, CI and probes` | 133 client examples (23,831), 12 integration tests (4,836), `horizon-world` examples (187 files), parity tools for deleted areas | root `members`, `.github/workflows/ci.yml` (`--workspace` → `-p` list), `tools/pr_ready.py`, `tools/parity.py` scopes, `[[test]]`/`[[example]]` entries | `cargo check -p horizon-client --all-targets`; `python3 -m unittest discover -s tests` | 28.7k |

After C14 the game graph should be ~**250 crates** (from 294) and ~**1.16M lines** (from 1.44M).
Run `cargo clippy -p horizon-client --all-targets -- -D warnings` and
`cargo clippy -p horizon-client --no-default-features -- -D warnings` (while a server build still
exists) before each commit; they are the cheapest way to catch a missed `#[cfg]` stub.

**Order rationale:** C1–C3 are free wins with no behavioral risk. C4–C6 are leaves with few
touchpoints. C7–C8 are the Horizon UI, which is where `game.rs` fields and every screen meet; doing
them before mods/shaders avoids editing the same 18k-line `game.rs` twice. C9 is the largest
"product" cut. C10–C11 are vanilla-adjacent and large. C12 is the highest-risk change in the tree
and should not block lite v1. C13 is target-specific and can ship in the same release. C14 is
hygiene and CI speed.

---

## 9. Honest ceiling: what "lite" cannot remove

The 1.44M lines are mostly *Minecraft*, not Horizon:

- `horizon-client` 650k: the game loop, 423 `game/` modules, mob AI, save, network, LAN hub.
- `horizon-client-render` 223k: chunks, meshing, light, `gfx.rs` + `gfx/` (73k), HUD, screens.
- `horizon-world` 193k: worldgen, block behaviour, NBT, datafixers.
- `horizon-protocol` 51k, `horizon-shaders` 24k, `horizon-core` 23k.

All cuts in §8 total **278,764 lines (19.3%)**, and that includes the launcher (113,794), all
probes/examples and integration tests (28,667 + 4,836) and the native mod API (18,892). Excluding
those, the actual game-code reduction is **≈117,000 lines (8.1%)**. A "lite" fork that keeps
Minecraft will still be a ~1.1M-line Rust codebase. The wins that matter are:

1. **Crate count and build graph** (294 → ~250–260), which removes rustc units from the cold build.
2. **The client lib tail** — `docs/build-times.md` measures the last two units at ~21 s (lib) and
   ~35 s (bin) of a ~100 s cold Linux dev build, and an edit in `game.rs` recompiles only that
   crate. Shrinking `game.rs`/`native_hooks.rs` is the only way to cut incremental time.
3. **No cfg matrix** — deletion is cheaper to maintain than two configurations.
4. **Binary size** — only crate drops and reachable-code removal help; the linker already strips
   unreferenced functions, so deleting an uncalled file saves build time, not bytes. Cosmetics,
   extras HUD, minimap and PvP are called every frame today, so those deletions *do* remove linked
   code.

The largest single build-time lever is C12 (native mod API): 13,391 lines of `native_hooks.rs`
plus 600 KB of generated source plus the `syn` parse of every `game/` file on every build. It is
also the riskiest. If a genuinely fast lite build is the goal, do C12 early; if a safe fork is the
goal, leave it.

---

## 10. Reproduction appendix

```sh
# source size
find crates xtask launcher -name '*.rs' | xargs wc -l | tail -1
# feature definitions
for f in $(find crates xtask -name Cargo.toml); do awk '/^\[features\]/{p=1} p' "$f"; done
# cfg sites (rg equivalent)
rg -n 'cfg[^\n]*feature = "' -g '*.rs' crates | grep -v target_feature | wc -l
rg -n 'cfg!\(feature = "horizon-extras"\)' -g '*.rs' crates
rg -n 'horizon_cosmetics' -g '*.rs' crates
# dependency graph / deltas
cargo tree -p horizon-client --offline --edges normal --prefix none | sort -u | wc -l
cargo tree -p horizon-client --offline --no-default-features --features friends \
  --edges normal --prefix none | sort -u
# generator inputs
python3 -c 'import json;d=json.load(open("native-hooks.json"));print(len(d["helpers"]),len(d["hooks"]))'
ls tools/native-hook-fragments | wc -l
```

Files worth reading before starting: `docs/forking.md` (the existing feature contract),
`docs/architecture.md` (area → files), `crates/horizon-mod-api-gen/src/build.rs` (generator
inputs), `crates/horizon-client/src/game/native_hooks.rs` (the 13k-line hook surface),
`crates/horizon-client-render/src/lib.rs` (132 modules), `crates/horizon-client/src/client_lib.rs`
(127 modules shared with `horizon-client-lib`).
