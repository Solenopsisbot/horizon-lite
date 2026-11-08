# Horizon Lite — assets, packs, shaders, mods, item/block data

Read-only survey of `/home/solenopsisbot/coding/mc/horizon-src` (1,443,639 Rust LOC in
`crates/` + `launcher/` + `xtask/`). Line counts are `wc -l` over `.rs` (comments and
`#[cfg(test)]` included unless stated). Nothing was built; numbers that need a build come from
the checked-in `target/debug/build/*/out` artefacts.

Verdict key: **CORE** = needed for a vanilla-looking game; **GATE** = keep the code, put it
behind one feature/flag; **CUT** = delete; **REWRITE** = replace, not delete.

---

## 1. Table

| Subsystem | LOC (Rust) | Verdict | Player-visible loss | Risk | Edit points |
|---|---:|---|---|---|---|
| `horizon-assets` (blockstate, item model, bake, resolve, palette) | 7,325 src | **CORE** | none — this *is* model decoding for vanilla assets | low | — |
| `horizon-assets` `obj.rs` + `item_model/foreign.rs` | 297 | **CUT** | none (no vanilla `.obj`; `obj` has no caller outside the crate) | trivial | `lib.rs` `pub mod obj` |
| Atlas definitions (`atlas_sources.rs`) | 500 | **CORE** | none — vanilla `atlases/*.json` | low | — |
| Sprite animation (`sprites.rs` 1,430 + `horizon-assets/animation.rs` 186) | 1,616 | **CORE** | water/lava/fire/prismarine stop animating if cut | low | — |
| Mipmaps (`mipmap.rs`) | 474 | **CORE** | vanilla Video Settings mipmap levels | low | — |
| Font (`font.rs` 1,881 + `client-core/lang.rs`) | 1,881 | **CORE** (unifont glyph provider GATE-able) | non-Latin scripts if unifont dropped | low | `font/` provider dispatch |
| `model_library.rs` + `models/` | 1,423 | **CORE** | none | low | — |
| Resource-pack discovery/layering/UI (`packs.rs` 1,997, `packs/cache.rs` 1,276, `pack_screen.rs` 1,968, `pack_browser.rs` 639, `game/packs.rs` 705, `game/server_packs.rs` 696, `game/packs/folder.rs` 84) | 7,365 | **GATE** | third-party + server packs, built-in Programmer Art/High Contrast, pack screen | med-high: `packs::` has 97 call sites in 28 files; the overlay root is also the datapack root host | `game/packs.rs:startup_root`, `game.rs:17682`, `options_ui` Page::ResourcePacks |
| Datapacks (`render/datapack.rs` 1,490 + world-loading/functions/save users) | 1,490 + users | **GATE** (not CUT) | world datapacks, `/function`, worldgen overrides | high — worlds carry them; `world_loading.rs` (12 sites), `functions.rs` (8), `save.rs`, `vanillagen.rs` | `datapack::discover*` |
| OptiFine/EMF: `horizon-optifine` (11,299) + CEM (`mobs/cem.rs` 1,365, `cem_anim.rs` 1,248) + CIT (`cit*.rs` 1,896, `item_render/cit.rs` 810, total 2,706) + `connected.rs` 1,284 + `fusion.rs` 687 + `block_entity_cem.rs` 630 + `random_textures.rs` 593 + `custom_sky` 659 + `native_emissive` 307 | ≈20,800 | **CUT** | CTM, emissive, random-entity textures, custom skies, CEM, CIT — all pack-only, zero vanilla effect | med: woven into `mesher.rs`, `block_entity_render.rs`, `hud.rs`, `mobs/render.rs`, `atlas_sources.rs` | see §3.4 |
| Shader packs, Iris format: `horizon-shaders` 21,204 + `gfx/pack_*.rs` 15,670 prod (6,958 test) + `shader_options.rs` 343 + `shader_ui.rs` 1,332 + `shader_pack_list.rs` 665 + `game/shader_packs.rs` 1,163 | ≈40,400 | **CUT** | `shaderpacks/` folder, Options > Shaders, shader options UI — opt-in only, nothing vanilla renders through it | med: 260 `pack_*` references in `gfx.rs`, 57 in `game.rs` | §3 |
| Horizon WGSL packs: `horizon-shader-api` 4,216 + `gfx/native_{pack,post,material,shadow,sky}.rs` 5,144 + `displace.rs` 707 + `game/native_shaders.rs` 318 | ≈10,400 | **CUT** | `.hshader` packs, "native" sky/material/post stages | med: `weather.rs`, `particles.rs`, `gfx.rs` bind groups | §3.3 |
| `horizon-polytone` | 1,817 | **CUT** | none — **nothing references it**: only `Cargo.toml` member + `AGENTS.md` row | trivial | `Cargo.toml:40` |
| Mod system (`horizon-mods`, `horizon-mod-api-gen`, `cargo-horizon-mod`, `horizon-mod-registry`, `horizon-mod-deps`, `horizon-port-pack`, game `native_*`, `mod_api`, `mod_content`, `mod_registry`, `mod_browser`, `.hmod/.hpack`) | ≈90,000 game + 17,100 launcher + 11,073 generated | **CUT** | mod browser, Mods page, `.hmod` content, native mods, modpacks, registry — no loss to a vanilla player | **high**: 204 files touched, ≈1,200 hook call sites | §2 |
| `horizon-items` | 9,804 | **CORE** | none | low | strip `content_namespaces.rs` (43) + the `mod_remainders`/`mod_function` branches in `items.rs` (~120) |
| `horizon-command` + `game/commands*` | 11,902 + 24,349 | **CORE** | `/data`, `/execute`, selectors, functions, command blocks are *vanilla*; cutting them is a design choice, not a size win | low (but 36k LOC if cut, and the tree is a network packet even in SP) | gate `/ban`, `/whitelist`, `/tempban`, chat-filter commands (`game/tempban.rs`, `game/chat_filter.rs`, `native_server::command_tree`) |
| `horizon-prepare` + 17 Java exporters | 7,995 + 2,226 Java (of a 51,266-line oracle tree) | **REWRITE** (keep, shrink) | without it: **no game at all** — see §4 | **critical**: this is the supply chain for 589 MB of assets | §4 |
| `native-hooks.json` | 152,708 bytes (177 helpers, 432 hooks) | **CUT** | none | med: `xtask mod-api`, launcher, `tools/native-hook-fragments/` | §2.2 |

---

## 2. The mod-system teardown

### 2.1 What actually exists (and what the docs still claim)

There is **no WebAssembly runtime** any more: no `wasmtime`, `wasmer`, or `wasm3` in
`Cargo.toml`/`Cargo.lock`. `horizon-mods/src/content.rs` is a *data* format (`.hmod` = assets +
data + block/item declarations), and "code mods" are **native Rust trait mods** linked into the
game binary by the launcher with `horizon-mixins`. `wasmparser` survives only to read an
`.hmod`'s imports for the registry's API-level check.

`.hmod` (content), `.hpack` (modpack), `.hshader` (shader pack) — `horizon-mods/src/manifest.rs`
decides the kind.

### 2.2 Delete list

**Crates (5 + 1 hollow)**

| Crate | src LOC | Notes |
|---|---:|---|
| `crates/horizon-mods` | 6,924 (src+tests) | `.hmod`/`.hpack` manifest, content fence, registry index (`index` feature) |
| `crates/horizon-mod-api-gen` | 2,182 | **build-dependency of two crates** — see the trap |
| `crates/cargo-horizon-mod` | 822 | `cargo horizon-mod new/build/run/check/registry` binary |
| `crates/horizon-mod-registry` | 2,275 | separate workspace (its own `Cargo.lock`, `Dockerfile`, `railway.json`) — a hosted service |
| `crates/horizon-port-pack` | 15,349 | launcher-only modpack porter (`Modrinth`/`CurseForge` → `.hpack`) |
| `crates/horizon-mod-deps` | 2 | empty crate; exists to keep 10 optional deps (mysql, redis, quinn, rusqlite, tungstenite, …) in `Cargo.lock` for mods to name |

Also remove the workspace members `Cargo.toml:25,29,31,34,35,38,40` region (mods, api-gen,
registry, port-pack, polytone, mod-deps, cargo-horizon-mod).

**Game crate — `crates/horizon-client`**

| Piece | LOC |
|---|---:|
| `game/native_hooks.rs` (639 `fn native_*`) | 13,391 |
| the other 78 `native_*.rs` modules (incl. `native_server.rs` 1,844, `native_block_entity_draw.rs` 1,186, `native_client_services.rs` 891, `machines/native_fluids.rs` 1,258; net of `native_shaders.rs` 318, which is the WGSL pack feature) | 22,205 |
| `mod_api.rs` 1,402, `game/mod_api_host.rs` 266, `game/mods.rs` 997 | 2,665 |
| `mod_content.rs` 2,927, `mod_content_biomes.rs` 638, `mod_content_tests.rs` 4,787, `mod_registry.rs` 334 + `tests.rs` 166 | 8,852 |
| `content_identity.rs` (registry hash sent on the wire) | 253 |
| `native_data.rs` (inside the 78 above) | (53) |
| `client_resources.rs` (render) | 143 |
| `game/mod_browser.rs` (client 167) + `render/mod_browser.rs` 189 + `render/mod_list.rs` 220 | 576 |
| `gfx/native_render.rs` (render hook ABI) | 393 |
| `horizon-protocol/src/mod_list.rs` (custom payload channel + compare) | 348 |
| `horizon-world/src/native_load_hooks.rs` + `worldgen/native_generate.rs` | 335 |
| `tests/mod_api_hooks.rs`, `examples/native_gui_overlay_probe.rs`, `wind_burst_hook_probe.rs` | 736+ |

**Build script / codegen**

- `crates/horizon-client/build.rs:9`: `horizon_mod_api_gen::generate(root, out_dir, Target::Client)` →
  writes `mod_api_generated.rs` (8,284 lines), `mod_api_generated_host.rs` (2,381),
  `mod_api_host_generated.rs` (377); 507 generated `dispatch_*` functions.
- `crates/horizon-client-render/build.rs`: whole file (7 lines) → `native_render_generated.rs` (31 lines).
- `native-hooks.json`: 152,708 bytes, 177 helpers + 432 hooks.
- `xtask/src/mod_api.rs` + `xtask/Cargo.toml` dep + `xtask/src/main.rs:53` `mod-api` task;
  `tools/native-hook-fragments/`, `tools/stamp_native_hooks.py`.
- Generated code is **referenced from the crate root**, not hidden: `mod_api.rs:979,1062`
  and `game/mod_api_host.rs:149` `include!(concat!(env!("OUT_DIR"), …))`, reached from
  `crates/horizon-client/src/lib.rs:9` `pub mod mod_api;` (unconditional) and
  `game.rs:279` `mod native_hooks;`. `main.rs` also has `static MOD_API_LEVEL = horizon_mods::api_level::MARK`
  so the *binary* links `horizon-mods` even with everything else gated.

**Launcher** (`launcher/`, separate workspace)

`native_mods.rs` 5,001 + `native_mods/` 3,206 + `mods_page.rs` 2,072 + `instance_mods.rs` 691 +
`rust_toolchain.rs` 1,514 (a portable rustc/cargo for building mods; only used by native_mods) +
`glass_mods.rs` 769 + `modpacks.rs` 757 + `modpacks_page.rs` 635 + `github_mods.rs` 685 +
`github_mods_page.rs` 556 + `glass_home_mods.rs` 226 + `browser/horizon.rs` 1,012 = **17,124**.
Plus `launcher/Cargo.toml` deps on `horizon-mod-api-gen`, `horizon-mods`, `horizon-port-pack`,
`horizon-shader-api`, `syn`, `proc-macro2`, `quote`, and `horizon-mixins` fetched from
`github.com/horizon-rust/horizon-mixins` at mod-build time (`native_mods.rs:41`).

**Other artefacts**

`docs/native-mods.md` 5,100, `docs/mods.md` 617, `docs/modpacks.md` 1,218,
`docs/mod-browser.md` 235, `docs/native-hooks-neoforge.md` 134, `docs/design/mod-hotload.md` 247,
`docs/design/registry-v2.md` 105, `docs/api/mod-index.md` 237, `docs/api/mod-files.md` 70.
CI: `.github/workflows/{cargo-horizon-mod,mod-registry,native-hook-stamp}.yml`,
`tools/{stamp_native_hooks.py,horizon_mod_binstall.py,mod_browser_harness.py,registry_backfill_owner_ids.py,ci/sign_native_build.sh}`.

**Total: ≈ 90,000 game Rust + 17,100 launcher Rust + 11,073 generated Rust + 152 KB JSON +
~7,600 doc lines + 6 CI/workflow files.**

### 2.3 Traps

1. **`generate` runs on every build of the client and re-reads 466 files / 305,832 lines
   under `crates/horizon-client/src/game/`** (`horizon-mod-api-gen/src/build.rs:track`,
   `Target::Client` → `directory(..., recursive)`). Any gameplay edit re-serialises the whole
   `game/` tree with `syn` and regenerates 11k lines. Removing codegen is also a **build-time**
   win, not only a binary one.
2. **`FillMode::Require`**: every catalog hook must have a matching `fn native_*` in
   `native_hooks.rs`. You cannot delete the file first — `native-hooks.json` and the functions
   must go in the same commit or the build script fails before rustc runs.
3. **`horizon-client-render/build.rs` reads `crates/horizon-client/src/game/native_hooks.rs`
   as its input** (cross-crate build input). Delete both build.rs files and both
   `[build-dependencies]` entries together.
4. **≈1,200 `.native_*()` call sites in 187 files** of `horizon-client`, plus 820 `mod_api::`
   references; 204 files are touched across `horizon-client`, `horizon-client-render`,
   `horizon-world`, `horizon-items`. These are not all
   mechanically safe: many hooks are *asked* for a value (`native_view_distance`,
   `native_camera_pose`, `native_biome_colors`, `native_terrain_model`) and the call site must be
   replaced by the vanilla value, not deleted. `native_hooks::mob_kind` is used by normal mob code
   (`game/creatures.rs:782,1345`, `pandas.rs:122`, `dispenser.rs:1837`, `entity.rs:1036`).
5. **`main.rs` links `horizon_mods::api_level::MARK`** — a 27-byte static that the launcher reads
   out of the binary with `horizon_mods::api_level`. Delete it with the launcher's mod page.
6. **`Screen::Mod`** (`game.rs:993,1024`) + `Screen::id()` mapping; `mods::ModsState`
   (`game.rs:3047`), `dev_mods` (`game.rs:663,807`), `mods::register_components`,
   `register_standalone_models`, `register_layer_definitions`, `mods::content_root`
   (`game.rs:17643-17687`). `UiResources::load` calls `built_with_native_mods()` to pick a
   mod-provided HUD image — inside the *core* asset path.
7. **`content_identity.rs`** gates multiplayer joins on a registry hash. Keep the vanilla path
   (it reads `registries.json` for protocol `Builtin`) or you break LAN/dedicated joins.
8. **Do not delete `mods/`.** 380 Java files / 51,266 lines are parity oracles; 17 `Vanilla*`
   classes there (2,226 lines) plus `PrepareWorker` are the **install-time exporters that
   `horizon-prepare` compiles**. The folder name is historical, not the mod system.
9. `horizon-extras` already gates the Mods *page* (`options_ui::HORIZON_EXTRAS`), so a
   `--no-default-features` build hides the UI but still compiles 90k lines and still calls
   ≈1,200 hooks. Gating alone gives you none of the win.

---

## 3. Shader packs — teardown

Two independent features share the word "shaders". Neither touches vanilla drawing.

### 3.1 Iris/OptiFine-format packs (`shaderpacks/*.zip`)

`horizon-shaders` (21,204 src) = pack reader + GLSL→naga translator. Consumers:
`gfx/pack_*.rs` (15,670 prod, 6,958 test), `shader_options.rs`, `shader_ui.rs`,
`shader_pack_list.rs`, `game/shader_packs.rs`. `Pack` is always `Option<…>` in the renderer
(`gfx.rs:6900` `pack: Option<horizon_shaders::Post>`); `hud/pack_text.rs` even makes the HUD text
shader optional.

**It is not used for vanilla rendering.** Vanilla post effects go through
`post_chain.rs` (2,201) + `post_glsl.rs` (316), which use `naga` directly and read vanilla's
`post_effect/*.json` + GLSL from the resource root. Keep both; they are CORE. (The only overlap is
`translate_core`, which is *resource packs* replacing `shaders/core/*` — see §3.5.)

Delete: crate `horizon-shaders`; `gfx/pack_*.rs` and `gfx/pack_post/`, `gfx/pack_atlas/`,
`gfx/pack_uniforms/`; `shader_options.rs`, `shader_ui.rs`, `shader_pack_list.rs`,
`game/shader_packs.rs`; `gfx.rs` (~260 refs), `game.rs` (~57), `options_ui.rs` (Video Settings →
Shaders page), `resource_load.rs` (`shader_packs::picks_material_pack` into the sprite budget),
`streaming.rs`, `mesher.rs`, `graphics_ui.rs`, `settings.rs` (`settings.shaders`), `split*`,
`control.rs` (launch API surface); `docs/shaders.md`, `docs/api/shaders.md`,
`docs/api/shaders-reference.md` (321), `docs/api/shaders-reference-0.2.md`.

### 3.2 Which crate is which

`horizon-shaders` = third-party pack *format* (GLSL). `horizon-shader-api` = **Horizon's own**
WGSL pack format and its `horizon-shader` authoring tool (`new`, `check`, `pack` → `.hshader`).
The game runs those as `gfx/native_pack.rs` (+`native_post` 2,603, `native_material` 862,
`native_shadow` 854, `native_sky` 388, `displace` 707). Only sample packs exist
(`crates/horizon-shader-api/packs/golden_hour*`); **no pack is installed by the game** — grep for
`golden_hour` in shipping code returns only a test. CUT both.

### 3.3 Coupling to watch

`horizon_shader_api` types leak into `gfx/weather.rs` (native weather pipeline),
`particles.rs` (`ParticleLight`), `gfx.rs` (`light_color`, bind group 0). Small, but they must be
unpicked before the crate goes. `horizon-mods`' `index` feature depends on `horizon-shader-api`
for the `shader` kind — removing both together is cleaner.

### 3.4 OptiFine (separate feature, same "pack files" bucket)

`horizon-optifine` 11,299 + ≈9,500 of consumers. All of it is opt-in pack behaviour: CTM,
`_e` emissive, ETF random textures, EMF/`.jem` models, CIT, OptiFine custom skies. Vanilla
rendering never enters these branches (e.g. `connected.rs` only runs when a `.properties` matched).
CUT; the risky part is `mesher.rs` / `block_entity_render.rs` / `hud.rs` / `mobs/render.rs`
call sites, not the crate.

`horizon-polytone` (1,817) is **dead code**: no dependency anywhere (`Cargo.toml:40` member and an
`AGENTS.md` row only). Delete for free.

### 3.5 What is lost, exactly

Nothing a vanilla player sees. Lost: `shaderpacks/` support, Horizon WGSL packs, the Shaders
page, shader option screens, `[material]`/`[sky]`/`[post]` stages, and — if resource packs are
also gated — packs that replace vanilla `shaders/core/*` (via `hud/pack_text.rs` +
`horizon-shaders::translate_core`). Keep `post_chain`/`post_glsl`: those draw vanilla's own
spider/creeper/underwater/nausea effects.

---

## 4. Minimum asset pipeline, and first run without `horizon-prepare`

### 4.1 The hard fact

The game ships **zero Minecraft files**. `no_resources.rs` (278 LOC) is a whole screen that says
"prepare the game files or quit", and `load_resources` (`game/resource_load.rs:405`) errors with
"Prepare resources with the launcher, or: `horizon-prepare --prepare`". A lite build without an
asset pipeline is a 589 MB hole you fall into at frame 1.

Prepared tree (`.local/horizon-client/26.3`, 589 MB): `assets/` (153 MB of textures for 9,790
sprite layers, models, blockstates, items, lang, fonts, shaders/core, post_effect),
`data/` (recipes, loot, advancements, tags, damage types, worldgen), `sounds/` (~380 MB), plus
~20 generated tables at the root: `facts.json`, `items.json`, `registries.json`,
`entity-types.json`, `entity-models.json`, `mob-data.json`, `model-states.json`,
`movement-properties.nbt`, `gameplay-facts.json`, `block-behaviours.json`,
`block-tags.json`, `render-definitions.json` + `occlusion.nbt`, `landing-definitions.json`,
`creative-inventory.json`, `command-registries.json`, `commands.json`, `cached-collision.nbt`,
`horizon-resources.json` (manifest, schema 7), `horizon-prepare.json` (stamp, OUTPUT_VERSION 3).

### 4.2 What is really needed

1. `assets/` + `data/` extracted from the player's `client.jar` and Mojang asset objects —
   **pure Rust, no Java.** This is the bulk (all 153 MB + all of `data/`).
2. The ~20 generated tables — these come from **executing** vanilla classes
   (`VanillaCollisionOracle`, `VanillaBlockBehaviourExporter`, …) and cannot be derived from the
   jar's JSON. They are the reason `horizon-prepare` needs a JDK and 52k lines of Java.
3. Optional: sounds (380 MB, can be a `--with-sounds` step), panorama, unifont, extra languages.

### 4.3 Three lite options

| Option | Work | First-run UX |
|---|---|---|
| **A. Keep `horizon-prepare`** | 0 — it already has `--check`, `--launch-api`, `--progress json`, stale-step skipping, and a shipped precompiled `exporters/` bundle so players only need a JRE | Unchanged: point at a Minecraft install, wait, play. Cost: 8k Rust + a Java runtime + the compiled `exporters/` bundle shipped in releases |
| **B. Split it** — Rust-only asset importer + pre-generated tables committed to the repo | Medium: extract `files.rs`/`inventory.rs`/`sounds.rs` (assets) from `artifacts.rs`/`lib.rs`; commit the ~20 JSON/NBT tables produced once by a maintainer from a Mojang install | One "locate your `.minecraft`" dialog, seconds, **no Java**. Tables are Horizon-derived facts, not Mojang assets — but they are version-pinned: a vanilla 26.3 bump requires regenerating them |
| **C. Ship the whole 589 MB** | 0 code | Blocked by the project's own `tools/check_public_tree.py` (`PRIVATE_ROOTS` includes `.local`, `assets`) and by only being able to redistribute what Mojang's terms allow. Not viable |

**Recommendation: B, with A as the fallback for a version bump.** Option B removes `java.rs`
(516), `exporters.rs` (226), `pool.rs` (145), the 17 exporter classes, and the "is a JDK
installed" branch of first-run — roughly half of `horizon-prepare` and *all* of the Java
dependency — while keeping `--check` semantics.

### 4.4 Loose ends a lite build must decide

- **Sounds** are 380 MB of the 589 MB. `Audio::silent` already exists; a lite build can run
  without them (silent game) or download them on demand.
- **Built-in packs** (Programmer Art, High Contrast) come from the asset index and are needed by
  `packs.rs`'s built-in list — if packs are gated, drop both.
- **`--resources` default and `no_resources.rs`** still need to point somewhere sensible if
  `horizon-prepare` is replaced; keep the diagnostics.
- **Manifest/stamp**: whatever replaces prepare must keep `horizon-resources.json`'s schema and a
  stamp, or the launcher's `--check`/`COMPLETIONS` (`launcher/src/backend.rs`) and
  `horizon-prepare::check` disagree and re-prepare every launch.

---

## 5. Suggested order (each step compiles on its own)

1. Delete `horizon-polytone` (1,817, zero users) and `horizon-mod-deps`.
2. Gate/Delete resource packs + OptiFine + both shader systems — biggest LOC per unit of risk
   after mods, and no gameplay call sites (all renderer/UI).
3. Mod ABI: delete `native-hooks.json`, both build scripts + build-deps, the three `include!`
   sites, `mod_api`, `native_hooks`, the 78 `native_*` modules, `mod_content`, `mod_registry`,
   `mod_browser`, `content_identity`'s mod half. Then sweep the 204 files.
4. Crates: `horizon-mods`, `cargo-horizon-mod`, `horizon-mod-registry`, `horizon-port-pack`.
5. Launcher: `native_mods*`, `mods_page`, `rust_toolchain`, `browser/horizon`, modpack pages,
   plus the `horizon-mixins` git fetch and CI workflows.
6. `horizon-prepare` → option B.
