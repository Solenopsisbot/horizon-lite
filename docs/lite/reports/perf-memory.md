# Horizon Lite — RSS and VRAM audit

Read-only survey of `/home/solenopsisbot/coding/mc/horizon-lite` (fork, 26.3 data, wgpu 30).
Nothing was built or run. Every number below is either **measured** (an existing benchmark artefact
or a log line), **derived** (a code constant times a count I can see), or **estimated** (a range with
its reasoning). File:line points at the code that decides the number.

The point of this report is not "make Minecraft smaller". It is: at the Lite defaults this game
already asks for ~0.9–1.1 GB RSS and ~270 MB VRAM; the audit says where that goes, which parts
are pure product surface, and which caches are over-provisioned by an order of magnitude.

---

## 0. Headline

| | Measured | Where |
|---|---:|---|
| RSS, steady (median during 4 flights) | **1,271 MB** | `/tmp/opencode/horizon/reports/raw/fast-standard-contended-r1-20261108T055439Z.summary.txt` |
| RSS, peak | **1,427 MB** | same |
| GPU allocated (wgpu) | **405 MB** | same (`memory.gpu_mb`) |
| Prepared resources on disk | **321 MB** (no sounds) | `du` of `.local/horizon-client/26.3` |
| Sounds on disk | **~380 MB**, not resident | `docs/native-client.md:74` |
| Block sprite array | **1,301 layers at 64 px** | benchmark log line 2 |
| Meshed sections at RD 12 | **16,398** | `chunks.*.meshed_count` |

Caveat: that run is commit `94ef9644` and a `target/fast` build (108 MB binary, no fat LTO). Re-run
the bench on the current tree before quoting the absolute RSS; the ratios and the code constants
are what this report is built on. The run also had audio off and a 4-scene flight path, both of
which change RSS (see §1 rows 5 and 13).

That run used `renderDistance:12` from the bench `options.txt`. Lite's `Settings::default` is now
**RD 8 / sim 6** (`settings.rs:223-224`), which is ~51 % of the column area of RD 12, so a fresh
Lite install should land near **0.9–1.1 GB RSS and ~270 MB VRAM**. Everything below is written for
RD 12 unless stated, because that is the only run we have numbers for.

The single most important structural fact for memory: **single player is a client plus an
in-process server**, and both hold the world. That is mitigated — `lan/handoff.rs` replaces the
client's decoded sections with the server's `Arc<Section>` when they are identical — but the
*second* copy of the chunk *records*, the encoder's wire bytes and the packet buffers are all real.

---

## 1. Ranked memory consumers (RSS)

Estimates for RD 12. "Confidence" says how much is code-derived.

| # | Consumer | Est. | Confidence | Evidence |
|---:|---|---:|---|---|
| 1 | **Chunk encoder section-wire cache** | **60–190 MB** | high | `lan/chunks.rs:321` keeps 32,768 section entries; every sent column caches all 24 sections (`chunks.rs:1080-1093`). At RD 12 the client+server keep ~1,320 columns → ~31,700 entries, i.e. essentially the full cap. A section's wire is ~4–8 KB (blocks 2–4 KB + up to two 2 KB light layers). |
| 2 | **Startup tables (see §3)** | **120–220 MB** | medium | registry 35,723 states (log), `FaceVisibility` 19 MB (comment `resource_load.rs:213`), collision 5.5 MB NBT, motion 4.2 MB NBT, behaviours + facts, model library + baked models, item defs, recipes, tags, advancements 4 MB (`advancements.rs:35`). |
| 3 | **Resident world columns** (client + server, sections shared) | **40–55 MB** | medium | ~616 client columns (r=14 circle, `streaming.rs:2828`, `2884-2888`) + ~707 server (r=15, `streaming.rs:2831`) × ~30–40 KB/column (24 sections: 8–12 non-uniform blocks @2–3 KB, 4–8 light arrays @2 KB, biomes, records). |
| 4 | **Generator biome/carver caches** | **0–96 MB** | high | `generator.rs:981` cap 16,384 biome chunks; comment at `generator.rs:3422`: "up to 16384, 6 KB each" = **96 MB**. Freed when all workers idle (`release_caches`, `generator.rs:2612`), so it is a *moving-player* cost, not a standing one. |
| 5 | **Audio decoded-sample LRU** | **0–64 MB** | high | `audio.rs:215` `CACHE_BYTES = 64 << 20`. Lazy: nothing decoded until a sound plays (`audio.rs:206-215`). Bench had audio off. |
| 6 | **HUD/UI atlas CPU copy** | **15–30 MB** | medium | 4096×5120 RGBA = 84 MB while building; lz4-compressed and the raw dropped after upload (`hud.rs:806-830`, `SpritePixels::pack` `assets.rs:150-180`). |
| 7 | **Chunk packet bodies in flight** | **10–60 MB** | medium | `MAX_PENDING = 96 MB` per client (`lan/io_pool.rs:22`), `AHEAD = 256 KB`; each chunk body is ~50–100 KB and a view is 600+ chunks. Peak driver while loading, drained after. |
| 8 | **Save queue (NBT of modified chunks)** | **20–80 MB peak** | medium | `save.rs:2790-2822`: `mpsc::channel` (unbounded) + `pending: HashMap` hold `Arc<NamedTag>` per queued chunk until the region writer finishes. A 5-minute autosave of a fresh area queues 600–2,500 chunks. |
| 9 | **Structure template cache** | **10–60 MB after villages/mansions** | medium | `worldgen/structure.rs:287`: `RwLock<HashMap<String, Option<Arc<StructureTemplate>>>>`, no eviction. 1,514 templates, 8.5 MB on disk; parsed block lists are several× that. |
| 10 | **Structure-start cache** | **10–30 MB** | low | `generator_structures.rs:134` 65,536 entries × `Starts`; two generations per shard (`:157-162`). |
| 11 | **Renderer CPU bookkeeping** | **5–15 MB** | medium | `gfx.rs:2562-2589` census: resident-section map, per-section layer lists, block-entity/light lists. Mesh CPU pool is separately capped at 16 MB/128 (`streaming.rs:363-364`). |
| 12 | **mimalloc heaps + thread stacks + binary text** | **150–350 MB (residual)** | low | purge delay 0 (`horizon-threads/src/lib.rs:362-373`) returns free pages, but each of 15 workers (log) keeps a heap; 8 MB stacks with worldgen/deep recursion touch several MB each; the `fast` binary is 108 MB and its touched text/rodata is RSS. |
| 13 | **Unattributed remainder of the 1,271 MB** | **~300–500 MB** | low | 4-scene benchmark continuously generates; decoration holds up to `workers*2` regions × 9 protos (`streaming.rs:1848-1895`) = 270 protos × ~150–300 KB ≈ **40–80 MB**, plus 45 generation protos (`workers*3`, `streaming.rs:2123`), final chunks, mesh jobs (480 in flight, `streaming.rs:2067`). **Close this with `horizon-ctl memory` + `alloc-census` (§12).** |

Cross-checks that make me trust the shape rather than the exact split:
- A dedicated/windowed host at RD 12 measured **1,194 MB** with two players and no benchmark churn
  (`docs/server-levels.md:58-63`). So ~1.2 GB is the product's real baseline, not a benchmark bug.
- "A closed level's memory goes back to the allocator, not always to the system"
  (`docs/server-levels.md:67`) — the residual is partly allocator retention.

### Ranked VRAM (405 MB measured at RD 12)

| # | Consumer | Est. | Evidence |
|---:|---|---:|---|
| 1 | **Section vertex arenas + sorted indices** | **~260–290 MB** | `405 MB − textures/targets ≈ 270 MB` over 16,398 meshed sections ≈ **16.6 KB/section**. Arenas: `arena.rs:14` pages ≤256 MB, initial 1 MB (`gfx.rs:4620-4624`), translucent arena initial 2^18 verts (`arena.rs:170-177`). Terrain vertex is 24 B (`mesher.rs:69-81`), already leaner than vanilla's 28. |
| 2 | **GUI/UI atlas** | **84 MB** | 4096×5120 RGBA, no mips (`gfx.rs:3560`, height at `hud.rs:1463`). The code comment `resource_load.rs:348` calls atlas+panorama "144 MB". |
| 3 | **Block sprite texture array** | **28.3 MB** | 1,301 layers × 64² × 4 B × 4/3 mips (`gfx.rs:1589`, `sprites.rs:119-124`). The log says 64 px because *one* 64×64 texture (`straw_bed.png`) raises every layer (`sprites.rs:236-260`). At 16 px the same set is **1.8 MB**. |
| 4 | **Depth + colour targets** | **~8 MB at 1280×720** | Depth32Float + 8-bit colour, sample_count 1 (`gfx.rs:2948`, `3191`). Scales with window²; HDR doubles the colour target. |
| 5 | **Entity/static buffers, indirect, lightmap, glint** | **~3–6 MB** | entity 2^14 verts (`gfx.rs:4598`), static entity indices 2^14 quads, indirect 20 KB (`gfx.rs:4755-4770`). |
| 6 | **LOD far tiles** | **0 by default** | `graphics.rs:785` `lod_distance: 0`; when on, `lod.rs` keeps unbounded ready tiles + `MAX_SAVED 1024` chunks (`lod.rs:24`). |
| 7 | **Shader-pack shadow buffers** | **0 by default** | when on: 2048² depth + up to 8 shadowcolour × 2 sides (`gfx/pack_shadow.rs:128-190`) = 16–280 MB. |

The VRAM model is: **sections ≈ 16.6 KB × meshed sections**, and meshed sections scale with the
*area* of the render distance:

| RD | client cols | meshed sections (est.) | section VRAM | total VRAM (est.) |
|---:|---:|---:|---:|---:|
| 6 | ~200 | ~5,300 | ~88 MB | ~200 MB |
| 8 (Lite default) | ~314 | ~8,400 | ~139 MB | ~255 MB |
| 12 (bench) | ~616 | **16,398 measured** | ~272 MB | **405 MB measured** |
| 16 | ~1,018 | ~27,000 | ~450 MB | ~575 MB |
| 32 | ~3,632 | ~96,000 | ~1.6 GB | ~1.75 GB |

That is why the old default of 12 and the "up to 32" slider are the largest memory decision in the
product, and why the 4 GB-card warning in `perf-measure.md` exists.

---

## 2. Startup: what is eager, what is lazy, what stays

Prepared folder is **321 MB** here (**589 MB** in the upstream asset report includes sounds; sounds
are 380 MB and are *not* in this tree). Nothing maps the whole folder: files are read individually.

Two upstream headline numbers do **not** transfer to this architecture:
- "9,790 layers" is a *stitched 2D atlas* tile count. Horizon uses a texture **array**, and the
  measured count is **1,301 block layers** (bench log). Those layers are cheap: 1.8 MB at 16 px,
  but 28.3 MB because one 64 px texture sets the array size (§1 VRAM).
- The full 589 MB is never resident. Eager tables are ~150–250 MB of *parsed* data; the other
  ~400 MB (sounds, worldgen JSON, data packs) is read on demand or not at all.

### Eager (read at launch, kept)
| Thing | Evidence | Approx resident |
|---|---|---:|
| Block registry, 35,723 states | log; `level/data.rs:629-636`; comment `registry.rs:25-27` says a 190k-state registry would be 125 MB | 12–25 MB |
| `facts.json` → `Properties` (5 bools/state) | `assets.rs:186-275` | <1 MB |
| `block-tags.json` (parsed, then dropped) | `assets.rs:192-230` | transient 1 MB |
| `block-behaviours.json` **kept as `serde_json::Value`** | `resource_load.rs:137,286`; used on `/reload` (`game.rs:17291`) | 6–10 MB |
| `Behaviours` (facts/shapes/tags, **second** `StateFacts` table) | `level/mod.rs:844-862` | 15–30 MB |
| `FaceVisibility` | `resource_load.rs:208-216`, comment "19 MB" | 19 MB |
| Block collision registry | 5.5 MB NBT (`worldgen/blocks/cached-collision.nbt`) | 10–20 MB |
| Motion resources | 4.2 MB NBT (`movement-properties.nbt`) | 6–12 MB |
| Models: `ModelLibrary` (all block+item model JSON) | `horizon-assets/resolve.rs:23-29` | 15–35 MB |
| Baked block models `StateModels.baked` | `models/catalog.rs:139-151` | 8–20 MB |
| Item definitions + `Items` + `ItemRenderer` | `items.rs:148-198`, `item_render.rs:661-680` | 10–20 MB |
| Recipes + recipe-book displays | `crafting.rs:1337-1350` | 5–10 MB |
| Advancements | `advancements.rs:35` says "~4 MB as Values" | 4 MB |
| Language map (current language only) | `client-core/lang.rs:440-480` | 1–2 MB |
| Sound registry (`sounds.json` events) | `sound_events.rs:259-300` | 1–3 MB |
| Block sprite pixels | `assets.rs:79-86`; comment "32 MB" | 21 MB raw → ~10 MB lz4 |
| HUD atlas pixels | `hud.rs:61-112` | 84 MB raw → 15–30 MB lz4 |
| Panorama | decoded on first title frame, then dropped (`panorama.rs:15-18,84-96`) | 0–24 MB transient |

### Lazy (only when asked)
- **Sound samples**: decoded on first play, LRU to 64 MB (`audio.rs:206-248,557-590`).
- **Structure templates**: opened from disk and cached forever on first use (`structure.rs:287`).
- **Far terrain / BlueMap / server terrain**: only with `lodDistance > 0`; `graphics.rs:785`.
- **Item baked models** (`item_render.rs:661` `baked`) and GUI item vertices (`gui_drawn`, capped
  8,192 entries at `item_render/gui.rs:264`).
- **Map textures**: 128×128 slots in the HUD atlas, re-uploaded as maps are shown (`hud.rs:122`).
- **Skins**: 128 slots in the HUD atlas (`hud.rs:140`).
- **Structure starts**, per-chunk; **poi** sections, per loaded chunk.

### Kept forever, and could be dropped
`behaviour_json` (only `/reload` needs it), the `ModelLibrary` (only a pack reload needs it), the
HUD atlas compressed copy (only a renderer rebuild needs it), all 54 `SpriteAnimation` frame sets
(only while animated sprites exist), and the encoder wire cache (§1.1).

---

## 3. World memory

### Column storage (live, client)
- 24 sections per Overworld column (`chunk.rs:11-13`). **The Nether and End are widened to the
  Overworld's −64..320** (`chunk.rs:107-112`, `147-153`): a Nether chunk allocates 24 sections where
  its dimension type has 16. That is ~33 % waste for every parked Nether/End chunk.
- `Section` = blocks `PalettedContainer` + biomes + `Light` (`chunk.rs:456-470`). Light is stored as
  uniform / 2,048-byte single layer / 4,096-byte full array (`chunk.rs:368-410`). Blocks are packed
  at 4–8 bits for local palettes, global width past that (`horizon-core/paletted.rs:1-110`).
- Heightmaps are lazy: `OnceLock<Box<[i16; 256]>>` each, dropped on a write that can move them
  (`chunk.rs:566-575`, `710-730`).
- There is a full census by part: `Chunk::census` (`chunk.rs:776-810`), surfaced by
  `horizon-ctl memory` (`game/memory.rs:88-170`). **Use it**; my per-column byte figure is an
  estimate, the census is exact.

### Chunk membership and eviction (the reason RD matters)
- Client keeps a circle of **radius + 2**, unloads past **radius + 3**
  (`streaming.rs:2820-2831`, `2884-2888`).
- Server keeps **radius + 3**, and generates to **radius + 3 (+ reach for decoration)**
  (`streaming.rs:2795-2818`). A fresh world therefore loads ~1.15× the client's columns on the
  server too.
- Parked dimensions keep everything until 300 idle ticks / 15 s, then save and close
  (`levels.rs:35,764-800`). Closing returns memory to the allocator, not necessarily to the OS
  (`docs/server-levels.md:67`).
- `simulationDistance` does **not** unload columns; it only limits ticking. Lowering it saves CPU
  and entity memory, not chunk memory.

### Meshes
- Client keeps only GPU handles plus per-section layer lists; CPU `SectionMesh` is freed after
  upload, with a reuse pool capped at **16 MB / 128 meshes** (`streaming.rs:363-364`).
- `MeshPool`/`SectionMesh` capacity is returned on worker idle (`streaming.rs:910-916`).
- `gfx::hold` can pin a second copy of up to **1 GiB** of new meshes (`gfx/hold.rs:21`), but only
  while a native mod calls `native_world_hold`. With mods gone this path is dead.

### Far terrain, LOD, BlueMap, server terrain (all default-off)
| Subsystem | Cap | Bytes at cap | File:line |
|---|---:|---:|---|
| `ServerTerrain.chunks` | 8,192 columns | ~**147 MB** (18 KB/column) | `server_terrain.rs:36,466` |
| BlueMap decoded tiles | 192 MB + 2,048 tiles | **192 MB** + | `bluemap.rs:41-42` |
| BlueMap columns | 4,096 | ~**74 MB** | `bluemap.rs:43,888` |
| BlueMap disk cache | 256 MB | disk only | `bluemap.rs:31` |
| `SaveDir.lod_decoded` | 1,024 chunks, 30 s TTL | **30 MB** ("each tens of kilobytes") | `save.rs:2445-2448` |
| `Lod.saved` summaries | 1,024 chunks | **~19 MB** | `lod.rs:24,2103-2117` |
| `lod` GPU tiles | unbounded by plan | tens–hundreds MB | `lod.rs:1266,1699-1701` |

**Default cost is 0** (`graphics.rs:785`). Enabled cost is **250–450 MB RSS + far-tile VRAM**, and
the sampling snapshots (`lod.rs:956-963`) copy maps per job, so it can spike. The distance knob goes
to `MAX_CHUNKS = 1 << 22` (`lod.rs:197`) but integrated GPUs are capped at 128 chunks
(`graphics.rs:599-611`), so "1024" is a distance, not a chunk count; the *caches* above are the
memory. This is the largest "delete it and gain a guarantee" item in the tree.

### Saves / region files
- `MAX_OPEN_REGIONS = 256` per cache × 3 caches (`save.rs:2017`): 768 open handles, ~8 KB index each.
- Pending writes are unbounded (`save.rs:2790-2822`); this is the peak, not steady, cost.
- `Chunk.saved: Option<Arc<ChunkExtras>>` retains unmodelled NBT (structure starts) for resident
  chunks; **not counted** by `ColumnCensus`.

---

## 4. Caches (and their caps)

| Cache | Cap | Verdict |
|---|---|---|
| Encoder section wire | 32,768 sections (`lan/chunks.rs:321`) | **over-provisioned 8×**; 60–190 MB |
| Encoder heightmaps | swept at 8,192 (`chunks.rs:165-167`) | fine |
| Compressed frame sharing | 32 MB (`lan/conn.rs:1849`) | pointless in single player (one client) |
| Sound samples | 64 MB (`audio.rs:215`) | halve for Lite |
| Biome/carver chunks | 16,384 (`generator.rs:981`) and 65,536 (`:1458`) | released on idle; lower caps |
| Structure starts | 65,536 (`generator_structures.rs:134`) | large; 8,192 is plenty |
| Structure templates | none | add LRU (128) |
| Region files | 256/file kind (`save.rs:2017`) | fine |
| LOD decoded chunks | 1,024 (`save.rs:2447`) | delete with LOD |
| Block-structure `saved_states` | 8,192 entries (`registry.rs:41-55`) | fine |
| Occlusion result cache | 16,384 (`occlusion_culling.rs:29`) | keep — this is speed |
| Particle light/section caches | 64 / 128 (`particles.rs:1303,1340`) | keep |
| Item GUI vertices | 8,192 (`item_render/gui.rs:264`) | keep |
| Sprite disk cache | 2.2 MB on disk (`sprite_cache.rs:18`) | keep, it avoids ~1,300 PNG decodes |
| Pack metadata | 8 open archives (`packs/cache.rs:302-314`) | fine |

Things that sound like caches but are not system-level consumers, checked so they can be dismissed:

- **Fonts.** The glyph atlas is rows inside the HUD atlas (`GLYPH_ROWS`, `hud.rs:115`), not a second
  texture; `Font.sheets` is rects and metrics (`font.rs:121-150`). The unifont `.hex` provider keeps
  ~100k small glyph structs (single-digit MB), parsed lazily per page.
- **Biome colours/grass colormaps.** `Biomes` holds 67 biomes and a few 256×256 `i32` maps
  (`biomes.rs`), ~1 MB. `ItemRenderer.grass` is another 256×256 `i32` (`item_render.rs:673`).
- **Pathfinding and mob AI.** Paths and brain "seen" caches are per-mob `Vec`s with small caps
  (`mobs/path.rs:238-250`, `mobs/animal_brain.rs:176`, `mobs/villager_brain.rs:175`). At the vanilla
  mob cap (tens) this is well under 5 MB; there is no global path cache to tune.
- **Screenshots/icons.** Pack icons, world icons and skins are fixed atlas slots (above), rebuilt on
  demand; screencaps use one readback buffer per request.

---

## 5. Allocator

- Global allocator is mimalloc (`horizon-threads/src/lib.rs:343-346`), with
  `mi_option_purge_delay = 0` (`lib.rs:360-373`) so free pages go back immediately.
  The comment records that the default delay held "a quarter more memory"; with 0 the overhead is
  "a few percent" over the system heap.
- Workers release their heap and the shared generator caches after **5 s idle**
  (`jobs.rs:75`, `jobs.rs:385-408`, `streaming.rs:910-916`). During continuous flight they never do,
  which is why a flying player's RSS is much higher than a standing one's.
- `release_free_memory()` also calls `malloc_trim(0)` on glibc (`lib.rs:405-420`) — covers native
  libraries (GPU driver, audio).
- Per-thread heaps: 15 workers (log) + render + server + network + IO + audio. 8 MB stacks, touched
  pages only; deep worldgen recursion makes this non-trivial but not top-5.
- `alloc-census` feature tags every allocation with 16 extra bytes and feeds
  `heap_by_tag_mb` (`Cargo.toml:135-137`, `heap_census.rs`). Measurement-only; it inflates RSS.
- `horizon_threads::allocator_commit()` (`lib.rs:375-400`) reports committed/peak bytes.

---

## 6. Duplicate data

1. **Client + server columns.** Real duplicate *records*; sections are shared after decode via
   `lan/handoff.rs` (`offer`/`take`). Do not remove that hand-off — it saves a whole world copy.
2. **Third copy: encoder wire bytes.** Blocks + biomes + light again, per section, in
   `ChunkEncoder.cache` (`lan/chunks.rs:185-190`). This is the biggest avoidable duplicate.
3. **Fourth copy in flight: packet bodies** between `Prepared::write()` and the client decode
   (`chunks.rs:407-440`), queued in `Outbox` up to 96 MB.
4. **Block textures on GPU twice**: 16/64 px terrain array and the same PNGs re-packed into the
   84 MB GUI atlas. The GUI only needs item/entity/GUI sprites at native size; block icons could be
   sampled from the terrain array or packed at 16 px.
5. **`StateFacts` twice**: `horizon_items::BlockFacts.states` and `Behaviours.facts`
   (`horizon-items/src/blocks.rs:243-246`, `horizon-world/src/level/mod.rs:850`), ~7 MB each.
6. **Block-entity NBT twice**: `Chunk.block_entities` keeps the raw tags after decode while
   `World.block_entities` holds the parsed `BlockEntity` (`remote_chunks.rs:289-305`).
7. **`behaviour_json`** keeps a 2 MB file as a `serde_json::Value` (6–10 MB) just for `/reload`.
8. **Arena CPU/GPU**: CPU vertex copies are dropped after upload (good); the only CPU copy is the
   16 MB mesh pool. `Renderer::keep_capture_copies` (render capture) deliberately keeps a full
   second copy and is off by default (`gfx.rs:1578`).
9. **String interning**: registry names, item ids and state names are `Arc<str>`
   (`items.rs:337-343`, `blocks.rs:36`), so item stacks and entity NBT share them. Chunk palettes
   are `u32` ids. No obvious interning gap beyond the per-state `String`s in the registry itself.

---

## 7. Defaults that drive memory

| Setting | Lite default | File:line | Memory effect |
|---|---:|---|---|
| `render_distance` | **8** | `settings.rs:223` | quadratic: VRAM and column count |
| `simulation_distance` | **6** | `settings.rs:224` | ticking/entities only, not columns |
| `entity_distance` | **0.5** | `settings.rs:241` | entity render count |
| `mipmap_levels` | **4** | `settings.rs:246` | +33 % sprite-array VRAM |
| `particles` | **2** (minimal) | `settings.rs:237` | particle count (cap 16,384, `particles.rs:1300`) |
| `max_fps` | **260** | `settings.rs:229` | no memory effect; CPU/GPU power |
| `vsync` | **false** | `settings.rs:230` | — |
| `clouds` | **false** | `settings.rs:233` | cloud geometry |
| `cloud_range` | **32** | `settings.rs:235` | cloud geometry if on |
| `biome_blend` | **0** | `settings.rs:243` | biome sampling |
| `weather_radius` | **3** | `settings.rs:247` | weather columns |
| `menu_blur` | **0** | `settings.rs:257` | menu target |
| `graphics.lod_distance` | **0** | `graphics.rs:785` | 0 MB; 250–450 MB if on |
| `blueMap.radius` | 64 (unused when LOD off) | `bluemap.rs:71` | tile fetch + cache |
| `texture_budget_mib` | **0** → 256 MB | `graphics.rs:804`, `sprites.rs:122-128` | lets 64 px win |
| `chunk_updates` | 0 (unlimited) | `graphics.rs:802` | upload burst size |
| `upload_budget_kib` | 0 (unlimited) | `graphics.rs:803` | staging burst |
| `workers` | 0 → cores−1 | `graphics.rs:1090-1105` | per-worker heaps/caches |
| `screenshot_quality` | **1** | `graphics.rs:821` | readback buffer 4×window px |
| `overlay` | Off | `graphics.rs:815` | debug charts |
| gpu/entity/particle/leaf culling | off | `graphics.rs:789-796` | speed, not memory |

The bench `options.txt` overrides RD/sim to 12 — that is why the 1,271 MB number is not the
Lite-default number.

---

## 8. Feature-removal candidates

| Remove | Steady MB saved | Peak MB avoided | Risk |
|---|---:|---:|---|
| **LOD + BlueMap + server_terrain + lod_net** (13.7k LOC) | 0 | **250–450 MB** + far-tile VRAM | low–med: self-contained (`render.md` §16 lists edit points); removes `SaveDir.lod_decoded` too |
| **Shader packs** (both formats, ~48k LOC) | 0 | 16–280 MB VRAM (shadow maps) + Naga IR | high: 260 refs in `gfx.rs` |
| **OptiFine pack features** (CTM/CEM/CIT/random/emissive) | 0 | up to 32 MB VRAM (random entity atlas `hud.rs:297`) | med: hooks in mesher/render |
| **Mod system** (`.hmod`, native hooks, mod UI) | 0 | 4 MB (mod image slot, `hud.rs:135`) + mod content caches | high call-site count; no memory win at default |
| **Studio recorder + replay** | 0 | 10–50 MB queue; **1 GB** replay (`mcpr.rs:22`) | trivial (`studio/`, self-contained) |
| **Agent control + input trace** | ~0 | 0 | trivial (`game/agent.rs`, `input_trace.rs` 512 events) |
| **Screenshots (scaled)** | 0 | 3.7 MB @720p, 33 MB @4K, ×64 at quality 8 | trivial; screenshot is a user action |
| **Telemetry session** | ~0 | 0 | trivial; bounded (`telemetry.rs:217-280`) |
| **Debug charts** | ~0 (240 samples, `debug_chart.rs:17`) | 0 | trivial |
| **Splitscreen** | 0 | 1 extra frame target set when on | med |
| **Frame generation / HDR / TAA / OIT / visbuffer** | 0 | 10–60 MB VRAM each when on | med |
| **Render capture** | 0 | **as much as all terrain meshes** (`docs/graphics.md:158`) | trivial; default off |
| **Chat filter / anticheat / server lists** | ~0 | 0 | trivial (server surfaces) |
| **`horizon-extras` leftovers (cosmetics, friends, Discord)** | ~0 | 0 | already default-off; code still compiles |

None of these are the big *default* win. They are insurance: the game should not be one user
setting (or one auto-detected BlueMap) away from +400 MB.

---

## 9. Tuning constants and defaults to change

| Where | Current | Change | Expected |
|---|---:|---|---|
| `lan/chunks.rs:321` `CACHE_SWEEP` | 32,768 | **4,096**, and drop a column's entries in `forget`/`unload` | **−50 to −150 MB** RSS; a revisited column is re-encoded on the warm-up threads (sub-millisecond), so the cost is tick-visible only on large teleports |
| `lan/conn.rs:1849` `SHARED_FRAME_BYTES` | 32 MB | **0 or 8 MB** for single player (one client) | up to −32 MB |
| `lan/io_pool.rs:22` `MAX_PENDING` | 96 MB | **16 MB** (single player's pipe drains fast) | −30–60 MB peak |
| `lan/hub.rs:5193` `INBOX_BYTES` | 16 MB | **4 MB** | peak |
| `audio.rs:215` `CACHE_BYTES` | 64 MB | **24–32 MB** | −32–40 MB in villages |
| `generator.rs:981` `CACHE_LIMIT` | 16,384 | **4,096** (still ~24 MB) | −72 MB while flying |
| `generator.rs:1458` carver ×4 | 65,536 | ×4 of the above | −2 MB |
| `generator_structures.rs:134` `START_CACHE_LIMIT` | 65,536 | **8,192** | −10–25 MB |
| `worldgen/structure.rs:287` template cache | unbounded | LRU **128** | −20–50 MB after villages |
| `save.rs:2790-2822` save queue | unbounded | bounded channel + pre-serialize on the writer | −40–70 MB peak |
| `hud.rs:122` `MAP_SLOTS` | 256 × 128² | **16** (4 MB → 0.26 MB) | −15.7 MB VRAM |
| `hud.rs:140` `SKIN_SLOTS` | 128 × 64² | **16** | −1.8 MB |
| `hud.rs:146-148` pack icons | 64 × 128² | **16** | −3 MB |
| `hud.rs:142` world icons | 32 × 64² | **8** | −0.4 MB |
| `hud.rs:151` trim slots | 32 | **8** | −0.1 MB |
| `hud.rs:954-959` `horizon/ui-text` | 2048×1024 | **1024×512** (no OSK) | −6 MB |
| `hud.rs:115` `GLYPH_ROWS` | 512 | **256** | −4 MB |
| `graphics.rs:804` `texture_budget_mib` default | 0 (256 MB) | **4** | block sprites 64 px → 16 px: **−26 MB VRAM**, −19 MB load CPU |
| `graphics.rs:785` `lod_distance` default | 0 | keep 0; delete the code | guarantee |
| `mipmap_levels` default 4 | 4 | **2** | −7 MB VRAM, slightly crunchier distance |
| `gfx/arena.rs:102-105` compaction | 128 MB free / 64 MB min | **64 / 32 MB** | returns pages sooner after travel |
| `gfx/hold.rs:21` `MAX_BYTES` | 1 GiB | **128 MB** (or delete with mods) | peak insurance |
| `chunk.rs:147-153` Nether/End widening | 24 sections | 16 for levels whose height is 256 | −33 % on Nether/End chunks (~10–15 MB per parked dimension) |
| `Cargo.toml:111-119` build profile | `fast` (108 MB binary) | ship **`profile.lite`** (fat LTO, panic=abort, debug 0) | −30–50 MB text RSS |

The `textureBudgetMiB` one is the best knob-to-effort ratio in the tree: `sprites.rs:165-171`
already downsizes the *whole array* to the largest side that fits the budget, and Lite has no packs
that need 64 px block textures.

---

## 10. Memory-for-speed: do **not** cut

- **Section hand-off** (`lan/handoff.rs`): turns the client's world copy into shared `Arc<Section>`s.
  Removing it costs a full second copy of blocks/biomes/light (~40 MB at RD 12, ~130 MB at RD 16).
- **Mesh reuse pool** (`streaming.rs:363-364`, 16 MB/128): removes per-frame allocator traffic and
  races with the renderer; the cap is already small.
- **Arena reuse and 256 MB pages** (`arena.rs:14`): fewer, larger buffers; the arena shrinks
  oversized pages (`arena.rs:424-441`) and compacts when ≥128 MB free, so it is not a permanent
  high-water mark. Cutting it trades ~50–100 MB for many more draw calls.
- **Translucent batching** (`graphics.rs:833`, `batchTranslucent`): costs 1–15 % extra terrain
  memory at RD 32 for 4–16 % FPS (`docs/graphics.md:45`). Keep — it is the one place extra VRAM buys
  real frames.
- **Encoder cache** itself (a *bounded* version): re-encoding every section on every re-entry costs
  measurable tick time in a 600-chunk view. Cut the cap, not the cache.
- **Sprite disk cache** (`sprite_cache.rs`, 2.2 MB on disk): avoids decoding 1,300 PNGs at every
  launch. Disk, not RAM.
- **Biome cache** (bounded): worldgen is the most expensive thing the game does; keep a few
  thousand entries.
- **Occlusion result cache** (`occlusion_culling.rs:29`) and **particle caches**: small and directly
  remove per-frame work.
- **`saved_states` palette cache** (`registry.rs:32-55`): saves NBT→state resolution on every column.
- **Mipmaps**: `mipmap.rs` is vanilla behaviour (`scaleAlphaToCoverage`); do not delete it to save
  the 33 %. Lower the level count instead.

---

## 11. Top 10 actions

1. **Cut the encoder wire cache to 4,096 sections and evict on unload** (`lan/chunks.rs:321`,
   `:664-668`, `:840-845`). Biggest single RSS win: 50–150 MB, low risk, re-encode only on revisit.
2. **Delete LOD + BlueMap + server_terrain + lod_net** (13.7k LOC). 0 MB today, 250–450 MB
   guarantee tomorrow, and it removes `SaveDir.lod_decoded` (30 MB), the two infinite caches and the
   per-tick `take_changed` plumbing.
3. **Shrink the GUI atlas's reserved slots** (`hud.rs:115-151,904-959`): 256 map slots → 16, skins
   128 → 16, pack icons 64 → 16, world icons 32 → 8, trims 32 → 8, ui-text halved, GLYPH_ROWS 256.
   ~30–45 MB VRAM and a shorter atlas.
4. **Fix the 64 px block-sprite blow-up.** Set `textureBudgetMiB: 4` by default (`graphics.rs:804`)
   or cap the array at 16 px (`sprites.rs:236-260`). 1,301 layers drop from 28.3 MB to 1.8 MB VRAM,
   and ~19 MB of load-time CPU; one texture loses detail.
5. **Bound the save queue** (`save.rs:2790-2822`): bounded channel, or serialize in the writer, and
   keep only the newest record per chunk. 40–70 MB off every autosave peak.
6. **Cap the generator caches and keep the idle release**: `CACHE_LIMIT` 16,384 → 4,096,
   `START_CACHE_LIMIT` 65,536 → 8,192, template LRU 128. 100–170 MB while flying, 20–50 MB at rest.
7. **Halve the audio LRU and zero the single-player frame-sharing cache**
   (`audio.rs:215`, `lan/conn.rs:1849`). 60–70 MB in a long village session.
8. **De-duplicate startup tables**: drop `behaviour_json` after building `Behaviours` (re-read on
   `/reload`), share one `StateFacts` vec between `BlockFacts` and `Behaviours`, and drop the
   block-entity raw NBT from resident `Chunk`s after decode. 15–30 MB.
9. **Make render distance the explicit memory dial**: default 8 is already good, but stamp the
   VRAM estimate in the UI and refuse/auto-lower 16+ on <4 GB cards (the table in §1 is the model).
   At RD 32 sections alone are ~1.6 GB.
10. **Ship `profile.lite`** (`Cargo.toml:111-119`) and add the memory gate: run the bench once per
    PR and record `memory.rss_steady_mb`, `memory.gpu_mb`, plus `horizon-ctl memory` counts
    (`client_columns.total_mb`, `server_generation.protos_mb`, `renderer.gpu.allocated_mb`). A
    regression should fail the PR, not be found by a player on a 4 GB card.

---

## 12. How to close the attribution gap (recommended before/after)

`horizon-ctl` already has the exact census this report had to estimate:

```sh
# live game, control socket on:
horizon-ctl memory
```

It prints (`game/memory.rs:88-170`):
- `process.resident_mb`, `allocator_commit_mb`, `allocator_peak_commit_mb`
- `client_columns` / `server_columns`: `blocks_mb`, `biomes_mb`, `light_mb`, `heightmaps_mb`,
  `section_records_mb`, `column_records_mb`, `unique_sections`, `uniform_block_sections`
- `shared_with_server` (sections deduped)
- `server_generation`: `protos_mb`, `light_views_mb`, `proto_sections_by_bits`, and the generator
  `caches` (biome count/bytes, carver entries, structure starts)
- `renderer.section_arenas_mb`, `section_vertices_mb`, `cpu.*`, `gpu.by_label_mb` (Vulkan/DX12)
- with `--features alloc-census`: `heap_by_tag_mb` by startup step, timed span, chunk job and thread

That is the only way to turn the "~300–500 MB unattributed" row in §1 into named owners. Suggested
A/B: default build vs (1) encoder cap 4,096, (2) audio 24 MB, (3) `textureBudgetMiB:4`, measuring
RSS steady/peak and GPU allocated at RD 8 and RD 12.
