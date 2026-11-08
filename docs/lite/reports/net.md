# Horizon Lite — networking, multiplayer, servers

**Source:** `/home/solenopsisbot/coding/mc/horizon-src` @ 2026-11-08 (read-only; no cargo builds run).
**Scope:** `horizon-protocol`, `horizon-client` net/remote/LAN/integrated/dedicated/friends, `horizon-server*`, `horizon-anticheat`, `horizon-chat-filter`, `horizon-bots`, `horizon-mcp`, `horizon-friends`, `horizon-relay`, control/agent.
**Method:** `wc -l` over source (tests included unless stated), `rg` dependency and call-site counts, line-level reading. LOC are exact file totals; "prod" = file minus its `#[cfg(test)]` module.

---

## 0. Headline

Single player is **not** a local simulation with an optional server bolted on. The window `Game` is a packet client of a second `Game` running on the "Server thread"; the two talk through `horizon_protocol::connection::Pipe` using the same handshake, login, configuration and play codecs as LAN. `remote.rs` (13,402 LOC, 903 `self.remote` references in `game.rs`) is the only code that applies world state to the window. The old in-frame path is gone: `--in-frame`/`--no-server-thread` only print "was removed" (`game.rs:847`), and `AGENTS.md` states it explicitly.

Therefore:

- **External networking is removable** — TCP listener/connect, status pings, online auth/encryption, server list, Realms, friends, dedicated server.
- **The in-process packet loop is not removable without a rewrite.** `horizon-protocol` cannot be deleted; it is the ABI between the two `Game`s.
- A "lite" build that deletes the *LAN transport* but keeps single player must still keep `conn::serve_local`, the login/configuration phase, `io_pool` and the hub. These are shared with single player.
- Roughly **82k LOC** of genuinely network-only code can go (**~89k** if the LAN transport is also deleted), while **~100–110k LOC** of "networking-looking" code stays.

---

## 1. Inventory

Verdicts: **CORE** = single player cannot run without it; **GATE** = removable with a feature/config switch or small stub; **CUT** = safely deletable; **REWRITE** = removable only by changing architecture.

| Subsystem | Files | LOC | Verdict | Risk | Exact edit points |
|---|---|---:|---|---|---|
| Protocol core: packet structs, codecs, framing, chunk/item/entity data, registry, ids, text, `horizon:*` channels | `horizon-protocol/src/{packets,item,buf,connection,entity_data,chunk,registry,ids,text,lib}.rs`, `crypto.rs`, `mod_*.rs`, `quiet.rs`, `menu_extra.rs`, `attachment_sync.rs` | **26,468** | **CORE** | High: 206 play variants (139 C / 67 S), 444 tests | Keep. Only trim adapter/status/servers below. |
| Protocol older-version adapter | `horizon-protocol/src/adapter/` | **24,197** (47.8% of crate; 220 of 444 tests) | **CUT** | Medium: 14 `ServerVersion` refs | Delete dir + `pub mod adapter`; stub `ServerVersion::Current` or remove compares at `net.rs:124,731`, `multiplayer.rs:291`, `lan/conn.rs:712`, `lan_particles.rs:462`, `remote_chat.rs:269`, `remote.rs:5516`. Also drops `accept_older_clients` (`lan/mod.rs:277`, `conn.rs:715`). |
| Protocol server-list/SRV/legacy ping helpers | `servers.rs` (367), `packets/status.rs` (50), `resolver/` (357) | 774 | **CUT** with multiplayer UI | Low | `net.rs:1384 ping`, `1473 ping_legacy`, `multiplayer.rs` callers; launcher uses `server_redirect` (`launcher/src/telemetry.rs:98`). |
| Client network thread — **local path** (`Session`, `connect_local`, `run` local branch, `configure`, `receive_play`) | `net.rs:122-486, 764-1128` | ~1,000 prod | **CORE** | High | Do not remove. `connect_local` at `net.rs:190`; local branch `784`; config `1129`; play loop `972`. |
| Client network thread — **external path** (TCP, status, online auth, transfer, friend, reconnect) | `net.rs` remainder (prod 1,507 total; 1,076 tests) + `reconnect.rs` 477 | ~1,200 | **CUT** | Medium | `connect_tcp:705`, `ping:1384`, `ping_legacy:1473`, `join_friend:557/595`, `older_server:731`, auth `Hello` branch ~840-880; drop `ureq` dep. |
| Remote client (packet handler) | `game/remote.rs` (13,402), `game/remote_*.rs` (5,975) | **19,377** | **CORE** | Very high | `connect_local:943`; `tick_remote`; do not touch. |
| LAN/server hub + local connection | `lan/{hub,conn,io_pool,chunks,entity,guest,tracking,playerdata,menu,containers,data,prediction,handoff}.rs`, `game/lan*.rs` | **~50,000** (lan dir 37,718; game/lan* 21,396) | **CORE** | High | `Lan::connect_local:783`; `conn::serve_local:599`, `serve_connection:626`, `login_and_configure:1153`; `io_pool` serves the `Pipe` (`Socket::Memory`, `io_pool.rs:485`). |
| LAN transport only: listener, accept, discovery, forwarding, transfer queue | `lan/mod.rs` listener ~250, `discovery.rs` 253, `forwarding.rs` 231, `arrivals.rs` 3,715, `import.rs` 616, `game/lan_screen.rs` 1,902, `integrated.rs` publish ~150 | **~7,100** | **GATE** (keep if Tier B) | Medium | `Lan::bind:731`, `listen_on:744`, `accept_loop:994`, `conn::serve:569`; `Publish` enum + `publish/unpublish` (`integrated.rs:1050/1067`), `apply_publish`. |
| Memory section sharing (server→own window) | `lan/handoff.rs` | 187 | **CORE** | — | Optimization that avoids double-storing chunks; keep. |
| Integrated server | `game/integrated.rs` | **1,409** | **CORE** | High | `open_integrated:390`, `poll_integrated_start:524`, `integrated_open:766`, thread `serve`; `NetConfig` at 816-841. |
| Server levels / dimension travel | `game/levels.rs` 923, `game/server_travel.rs` 1,264 | 2,187 | **CORE** | — | Every player (owner included) is a hub guest. |
| Dedicated supervisor binary | `horizon-server/` | **19,769** (179 tests) | **CUT** | Low | Remove workspace member. It has **no dependency on the game crate**; it spawns `horizon-client --dedicated` (`engine.rs:269`). |
| Dedicated mode inside the game | `game/dedicated.rs` (2,714) + `game/dedicated/` (2,374), `game/net_harness.rs` 156 | **5,244** | **CUT** | High: 108 `options.dedicated` refs | `game.rs:122 mod dedicated`, `656 field`, `830 --dedicated`, `17560 preflight`; `loading_window.rs:358 run_dedicated`; convert remaining checks to `serving.is_some()`. |
| `horizon-server-files` | 9 files | 2,868 | **GATE** | Medium | `json`, `properties::ResourcePackInfo`, `java_properties` are used by LAN/single player (`lan/conn.rs:64,1499`; `flatgen.rs`; `control.rs:128`). `eula`, `user_lists`, `user_cache`, `profiles` (~1,158) go with dedicated/LAN ops. |
| Anticheat | `horizon-anticheat` 1,052 + `lan/anticheat.rs` 597 + `lan/prediction.rs` 1,498 | 3,147 | **GATE** | Medium: types embedded in `Guest` (`guest.rs:219`) | Checks are already off unless `server.toml` enables them. Cutting needs a `Player`/`Record` stub and removal of `record/replay` blocks in `hub.rs:3068,3152,3541,4007`. |
| Chat filter / tempban | `horizon-chat-filter` 1,171 + `game/chat_filter.rs` 537 + `game/tempban.rs` 570 | 2,278 | **GATE** | Medium | `Hub.chat_filter: Option` is `None` unless dedicated; remove fields + `hub/chat_filter.rs` (247). `tempban` mixes `/ban` command support. |
| Load-test bots | `horizon-bots` | 1,784 | **CUT** | Low | Dev-only; delete crate + `tools/server_bench.py`. |
| Play with Friends | `horizon-friends` 4,675 + `horizon-relay` 2,377 + `game/friends.rs` 334 + `friends_screen.rs` 340 (+32 stub) | **7,758** | **CUT** (already GATE) | Very low | Feature `friends` already exists with `game/friends_off.rs`; remove from both manifests' defaults, drop deps, delete crates and `net.rs:492-606`, `multiplayer.rs:2296`. |
| Realms | `realms.rs` + `realms/client.rs` + `upload.rs` | **8,609** | **CUT** | Low | Title button + `realms` module; requires `auth` only for online. |
| Server list / direct connect UI | `multiplayer.rs` (prod 2,189, tests 819) | **3,008** (keep ~300) | **CUT** mostly | Medium | `servers.dat` `204`, official/partner `387/429`; keep `Screen::Disconnected` + `wrap` (used by `remote.rs:1576` and singleplayer failures). |
| Online/Mojang auth | `horizon-client-render/src/auth.rs` | **946** | **GATE** | Medium | `join_server:296`, `has_joined:570`, `fetch_chat_keys`, `ureq`; used by LAN online-mode (`conn.rs:851`), title status, cosmetics. Offline build can stub `current()`, but keep `offline_uuid` ownership. |
| Server resource packs | `server_packs.rs` 910 + `server_packs/download.rs` 596 + `game/server_packs.rs` 696 | **2,202** (keep ~400) | **GATE** | Medium | `server_packs_world_pack` (`game/server_packs.rs:218`) serves `saves/<w>/resourcepacks/resources.zip` in single player; keep local path, delete download/prompt (496-910). `remote.rs:994` passes `None` for local. |
| Server links dialog | `game/server_links.rs` | 595 | **CUT** | Low | `C->ServerLinks` event + pause button. |
| `lod_net` far terrain | `lod_net.rs` 555 + `lod_net/{server,client}.rs` 686 + `game/lan_far.rs` 79 | 1,241 + 79 | **GATE** | Low | Client ignores it for its own server thread (`render_settings.rs:91`), but integrated still builds a `Service` because `lod_distance` defaults to 64. Set `lod_distance: 0` in `integrated.rs` `NetConfig` (816) for a free win; keep for Tier B LAN. |
| Control socket + `horizon-ctl` + MCP | `control.rs` 794, `game/control.rs` 1,742, `bin/horizon-ctl/*` 2,635, `horizon-mcp` 476 | **5,647** | **GATE** | Low | `--control` arg; `game.rs:54,450` modules; `client_lib.rs` MCP dep. Not player-facing, but every harness uses it. |
| In-game agent/events/UI control | `game/agent.rs` 2,264 + `agent_navigation.rs` 439 + `agent_settings.rs` 255 + `ui_control.rs` 220 + `events.rs` 362 | **3,540** | **GATE** | Low | Follows control socket. |
| Splitscreen (adjacent) | `game/split.rs` + `game/split/` | 3,430 | **GATE** | Low | Uses the same `Pipe` (`Integrated::join_split`, `integrated.rs:186`); remove with Tier A's no-local-guests rule. |
| Velocity forwarding | `lan/forwarding.rs` | 231 | **CUT** | Low | Only when `forwarding_secret` is set (dedicated), `conn.rs:637,990`. |

No QUIC exists anywhere. The only UDP is DNS in `horizon-protocol/src/resolver` and STUN in `horizon-friends`.

---

## 2. Can Horizon Lite be strictly single player and delete all networking?

**No — not "all networking". Yes — all *external* networking, and that is the right target.**

### 2.1 Exactly how single player depends on the server path

1. `Game::open_integrated` (`integrated.rs:390`) spawns a thread named `Server thread` running `serve` → `server_game`: a second `Game` with `ExecutionRole::IntegratedServer`, no window, no audio device, its own `Options`.
2. `integrated_open` (`766`) constructs `HubConfig { integrated: true, max_players: 8, … }` and `NetConfig { listen: false, online: OnlineMode::lan(), gate: owner-only-through-memory, ..NetConfig::lan(0, …) }`, then calls `lan_host` (`game/lan.rs:1363`).
3. `Lan::start_with` (`lan/mod.rs:677`) creates the `Shared` state and `Hub` — the authoritative 20 Hz world/players — and because `listen == false` binds no socket. `hub.lan.connect_local()` (`mod.rs:783`) creates `Pipe::pair()` and a `horizon-local-conn` thread running `conn::serve_local` → `serve_connection` → handshake/login/configuration → `io_pool::adopt` for play.
4. The server end of the pipe is sent back through `ready`; the window's `poll_integrated_start` (`524`) calls `connect_local` (`game/remote.rs:943`) → `Session::connect_local` (`net.rs:190`) → `run` with `Connection::local(pipe)` (`net.rs:784`). It sends `handshake::Intention`, `login::Hello`, receives `LoginFinished`, sends brand/client information, runs `configure` (registries, tags, known packs, content hash, mod list), then `receive_play` decodes `play::Clientbound` into `Event`s.
5. `Game.remote = Some(Remote)`; `Game::tick` returns `tick_remote()` immediately (`game.rs:7564-7586`). The window never ticks a world itself. `remote.rs` applies chunks/entities/inventory/chat and sends `play::Serverbound` back through the same pipe.
6. The server thread ticks the world (`run_integrated_inner`), the hub encodes `Clientbound` bodies, `io_pool` frames them (no compression, no encryption for memory connections — `conn.rs:1162`, `987`) into the pipe.

What single player **does** exercise: all play packet types, framing, login/configuration, `Lan`/`Hub`, `conn::serve_local`, `io_pool`, `remote.rs`, `handoff`.
What it **does not**: TCP bind/accept, status ping, online auth, encryption, compression, discovery, adapter, server list, Realms, friends, dedicated config.

### 2.2 The three candidate architectures

| Option | What it means | Cost | Verdict |
|---|---|---|---|
| **A. Keep integrated server + in-memory packet loop** (current) | Delete external transports only. The `Pipe`, login/config and `io_pool` stay. | ~80k LOC delete, mostly mechanical; 2–4 weeks | **Recommended.** It is the only option with a tested upstream path and no gameplay rewrite. |
| **B. Direct typed handoff** | Replace byte encode/decode between the two threads with a channel of `Box<play::Clientbound>` / `Serverbound`; keep the packet *types* (and chunk/item codecs), drop framing/login/config/keep-alive. | ~1–2k edited LOC across `io_pool`, `conn`, `net`, `remote`; high concurrency risk; protocol core still ~26k | Optional v0.2 performance/elegance pass. Saves CPU on the server thread, not much LOC. |
| **C. Direct in-frame world ticking** | Delete the server thread and make the window `Game` tick `tick_world` itself. | The in-frame code was deleted; `remote.rs` and `hub` would need re-integration; effectively a different engine | **Not viable.** Months, high regression risk, loses LAN forever. |

The minimal change the brief asks about — "keep integrated server, delete TCP/QUIC/login handshake" — is right about TCP (and there is no QUIC), but **do not delete the login handshake**: the memory connection uses it to deliver the player profile, registries, tags, known packs, content hash and mod list. Cutting just that handshake is ~700 lines of work for no measurable win.

### 2.3 Can `horizon-protocol` be removed?

**No.** It is the interface between the server `Game` and the window `Game`. If one insists, these pieces have to be re-homed first (all small, but they are why "delete the crate" is not a clean cut):

- `crypto::{offline_uuid, uuid_string, md5}` — 56 refs / 31 files in client, render, server-files, launcher.
- `text::{Language, plain, translatable}` — 43 refs / 25 files (chat, UI).
- `packets::configuration::ClientInformation` — settings/render.
- `entity_data::PositionSource` — particles.
- `packets::login::Property`, `rsa::*`, `secure_chat::*` — auth, chat, skins.
- `buf`, `packets`, `item`, `chunk`, `registry`, `entity_data`, `connection::Pipe` — the core.

Dependants besides the client (so "who else breaks"): `horizon-command/src/network.rs` (command tree wire form), `horizon-client-render` (auth/skins/settings/particles/chat/containers), `horizon-server-files` (uuid/rsa/md5), `horizon-bots`, and `launcher` (`server_redirect`, `offline_uuid`). **`horizon-world` and `horizon-core` do not depend on it.**

What can go from the crate: `adapter/` (24,197), `servers.rs` (367), `packets/status.rs` (50), and optionally `rsa`/`secure_chat` if online chat/mode is fully cut (2,007). Floor ≈ **23.6k LOC**.

---

## 3. Ranked removals (LOC + effort)

Effort: S ≤ 1 day, M 2–4 days, L 1–2 weeks, XL > 2 weeks (one dev familiar with the tree).

| # | Package | LOC | Effort | Notes / payoff |
|---|---|---:|---|---|
| 1 | **Play with Friends** — crates `horizon-friends`, `horizon-relay`, client screens/net branches | **7,758** | **S** | Already feature-gated; `friends_off.rs` stub exists. Flip `friends` off in both manifests, remove crates and 5 cfg sites. Highest value/effort. |
| 2 | **Dedicated supervisor** — `horizon-server` + `horizon-bots` | **21,553** | **S** | Separate workspace crates; no game edits. Removes 179 server tests and 43 tool scripts' target. Does not remove `--dedicated` from the game. |
| 3 | **Realms** — `realms.rs`, `realms/`, title entry | **8,609** | **S** | Pure online UI; offline build never reaches it. Keep `multiplayer::Screen::Disconnected` for singleplayer errors. |
| 4 | **Protocol adapter (old versions)** — `adapter/` | **24,197** | **M** | Biggest single deletion. 14 call sites; stub `ServerVersion::Current`. Also halves protocol tests (220/444). Loses joining 26.2 servers and accepting old clients on LAN. |
| 5 | **Multiplayer client stack** — server list/direct connect, outbound `net.rs`, online auth, reconnect, server packs download, server links, protocol status/SRV | **~8,500** | **M** | `multiplayer.rs` cannot be deleted wholesale (`Disconnected`, `wrap`). Drops `ureq`, `sha1`, most of `net.rs`'s 1,076 test lines. |
| 6 | **Dedicated mode in the game + anti-cheat/chat filter** — `game/dedicated*`, `net_harness`, `horizon-anticheat`, `lan/anticheat`, `lan/prediction`, `horizon-chat-filter`, `game/chat_filter`, trim `server-files` | **~11,300** (plus 4,331 arrivals/import if not in #7) | **L** | 108 `options.dedicated` refs; anticheat types embedded in `Guest`. High touch count, low runtime payoff (all off in single player). Best done after #2. |
| 7 | **LAN transport but keep hub** — listener/accept, discovery, forwarding, arrivals/import, Open-to-LAN UI, integrated publish | **~7,100** | **M–L** | **Recommendation: do NOT do this for v0.1.** Saves little, and every singleplayer join traverses `conn::serve_local` + `io_pool`. Keep LAN (Tier B) or leave it compiled but never listening (Tier A). Deleting it is a Tier-A cosmetic cut with real regression risk. |
| 8 | **Typed handoff (option B)** | 0 deleted; ~1–2k edited | **L** | Performance/architecture cleanliness only. Not a LOC cut. |
| 9 | **In-frame ticking (option C)** | — | **XL** | Not available; would re-port the engine. |

Strict Tier A (single player, no LAN/friends/dedicated/online) removes **≈ 82k LOC** without the LAN transport (#1–#6), or **≈ 89k** if #7 is also done, and keeps **≈ 100–110k LOC** of protocol + hub + remote + integrated + `game/lan*`. If #7 is skipped (recommended), remove **≈ 82k**, keep **≈ 107k**.

Interaction with the product spec: its Tier-A bullet "LAN: TCP listener, connection handshake, I/O pool, discovery, Open-to-LAN UI" should be corrected — the **handshake and I/O pool are single player's path**. Only the listener/accept/discovery/publish subsets are LAN-only.

---

## 4. Coupling warnings

1. **`remote.rs` is not multiplayer-only.** 19,377 LOC and 903 `self.remote` refs in `game.rs`; `tick()` dispatches to it whenever `remote.is_some()`, which includes single player. Any "remove multiplayer" sweep that touches it breaks the game.
2. **`lan/conn.rs` + `io_pool.rs` are single player's transport.** `serve_local` (`599`), `serve_connection` (`626`), `login_and_configure` (`1153`) and `io_pool` (mio, `Socket::Memory`) serve the owner's `Pipe`. Do not delete with the TCP listener.
3. **`mio` is not a networking dependency here.** It polls the in-memory pipe (`io_pool.rs:485`). Removing it means replacing `io_pool` (982 LOC), not deleting a socket.
4. **Protocol types leak outside the client:** `horizon-command/src/network.rs` (command tree), `horizon-client-render` (`auth`, `skins`, `settings`, `particles`, `chat`, `containers`), `horizon-server-files` (`profiles`, `user_lists`, `properties`), `launcher` (`telemetry`, `profile_heads`). Deleting `horizon-protocol` means moving these leaves first.
5. **`horizon-client` and `horizon-client-lib` compile the same sources.** `horizon-client-lib`'s manifest points at `../horizon-client/src/client_lib.rs`; deleting `net.rs`/`lan/` breaks both the `horizon-client` and `horizon-client-lib` targets and `horizon-ctl`.
6. **`horizon-server-files` is re-exported as `horizon_client::server`** and used by `lan/conn.rs` for its JSON parser and `ResourcePackInfo`, by `flatgen.rs` and by `control.rs`. It cannot be removed just because the dedicated server goes; trim only eula/user lists/cache/profiles.
7. **Anticheat types are embedded in the hub guest** (`guest.rs:219`), even when checks are off. Removing the crate needs a stub, not just deleting the config loader.
8. **`multiplayer.rs` is partly core:** `Screen::Disconnected` and `wrap` are used by singleplayer disconnects (`remote.rs:1576`). Keep a ~300-LOC remnant.
9. **Server resource packs have a local path:** `server_packs_world_pack` loads `saves/<world>/resourcepacks/resources.zip`. Keep that; only downloads/prompts are server-only.
10. **`horizon:brand` negotiation enables extensions.** The client sends `vanilla` until a server identifies as `horizon`, then echoes `horizon` (`net.rs:1181-1194`), enabling `horizon:mod_list`, `horizon:block_registry`, `horizon:mod_net`, `horizon:quiet_commands`, `horizon:menu_extra`, `horizon:attachment_sync`, `lod_net`. The integrated server is a Horizon server, so these run in single player. If mods go, these channels can go; while mods stay, keep them.
11. **Splitscreen uses the same pipe** (`Integrated::join_split`, `integrated.rs:186`). If Tier A removes splitscreen, remove `game/split*` (3,430) too, but it does not remove the pipe.
12. **`OnlineMode::lan()` generates an RSA key pair at world open when the player is signed in** (`lan/mod.rs:184`, `integrated.rs:820`), even though the memory owner bypasses it. Setting `online: None` and `lod_distance: 0` in the integrated `NetConfig` are free singleplayer wins.

---

## 5. Tests and harnesses that need net

| Area | Tests / size | What breaks if cut |
|---|---|---|
| `horizon-protocol` | **444 `#[test]`**, 220 in `adapter` | Codec spec; adapter deletion is also a test deletion. |
| `lan/` | **351 `#[test]`** (hub 1,177 test LOC, conn 429, mod 219, entity subdirs) | Login/config, hub, chunk encoding, transfer, anticheat. |
| `net.rs` | 20 tests, 1,076 test LOC | Status, legacy ping, local login, compression. |
| `remote.rs` | 41 tests | Packet application. |
| `multiplayer.rs` | 22 tests | Server list parse/ping. |
| `crates/horizon-client/tests/lan_bot.rs` | **2,299** LOC | Headless LAN client; needs a live server. |
| `tools/` | **43** scripts matching lan/server/friend/net/bot; `lan_e2e.py` 14,100 LOC, `agent_control_e2e.py` 1,179 | CI nightly runs `lan_integration` (~2,400 s). Server e2e: 20+ scripts (`server_*_e2e.py`, `test_server_*`, `test_lan_*`, `test_friends*`). |
| `horizon-server` | 179 tests | Delete with crate. |

A lite fork must keep a **singleplayer smoke test** (open world → chunk → break/place → save/reload) and can drop the LAN/dedicated/friends matrix. If LAN is kept (Tier B), keep `lan_e2e.py` at least for host+1 guest; it is the only end-to-end proof that `serve_local`/`io_pool`/`remote` still work.

---

## 6. Concrete minimal plan (Tier A, recommended order)

1. **Features first (S):** in `crates/horizon-client/Cargo.toml` default `["audio","controllers"]` and `horizon-client-lib` default without `friends`/`discord`/`heartbeat`; delete `horizon-friends` and `horizon-relay` from the workspace. No code edits beyond the manifests (stubs already exist).
2. **Supervisor (S):** remove `horizon-server`, `horizon-bots` workspace members and `tools/server_*` from CI. The game still accepts `--dedicated`; it just has no supervisor.
3. **Online surfaces (M):** delete Realms, server list/direct-connect, status/legacy ping, reconnect, online `join_server`, server-pack downloads, server links. Keep `multiplayer::Screen::Disconnected` and the local world-pack path.
4. **Adapter (M):** delete `horizon-protocol/src/adapter`; add a 20-line `ServerVersion` stub or drop the comparisons.
5. **In-game dedicated + filters (L):** remove `--dedicated`, `game/dedicated*`, `net_harness`, then stub anticheat/chat-filter. Leave `options.dedicated` as `None` only if removing 108 refs is too risky; the field itself costs nothing at runtime.
6. **Do not touch** `integrated.rs`, `remote*.rs`, `lan/hub*`, `lan/conn.rs`'s local path, `lan/io_pool.rs`, `lan/handoff.rs`, `game/lan*.rs`, `game/levels.rs`, `game/server_travel.rs`.
7. **Free wins in `integrated.rs`:** `online: None`, `lod_distance: 0`, `announce: false` (already `listen:false`).
8. **Optional later:** typed handoff (option B) to drop framing/login/keep-alive between threads; then, and only then, `connection.rs`/`frame.rs` can shrink.

Expected end state: one binary, no `AF_INET` from single player, no server-list/friends/Realms/dedicated code, protocol core + hub + in-memory packet loop intact, worlds and gameplay unchanged.
