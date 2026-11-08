# AGENTS: working in horizon-lite

This is a **fork**, not the upstream project. The rules below replace the upstream `AGENTS.md`
that shipped with the import commit.

## The relationship to upstream

- Never open a pull request, issue, or discussion against `horizon-rust/horizon` for work done
  here. We do not upstream. There are no `/claim` rules, no release train, no maintainer to ping.
- Attribution is in `NOTICE`, `LICENSE` and `THIRD_PARTY_NOTICES.md`. Keep them.
- Never commit Mojang's files: jars, assets, decompiled source, or prepared resources. `.local/`
  is ignored, and `tools/check_public_tree.py` guards the tree. Keep that guard working.
- Keep "unofficial" language in the README and any user-facing build metadata. Never imply this
  build is official Horizon.

## Product fence

`docs/lite/PLAN.md` is the scope. The short version: single-player-first, no launcher, no account,
no internet service, no telemetry, no mod registry, no dedicated-server supervisor, no release
signing. Features outside that fence are not added back "just because the code exists".

The one architectural non-negotiable: **single player runs as a client of an in-process server
thread.** `game/integrated.rs` → `lan::Lan::connect_local()` → `horizon_protocol` packet loop.
`remote.rs`, `lan*.rs`, `integrated.rs`, `levels.rs` and `src/lan/` are the game loop. Do not
delete them to "remove multiplayer"; that is a 250–400 hour re-port, not a cleanup.

## Build and check

```sh
cargo check --workspace --all-targets          # the main gate
cargo check -p horizon-client --no-default-features
cargo test -p horizon-client --lib
cargo fmt --all
cargo clippy -p horizon-client --all-targets -- -D warnings
```

Linux needs `libasound2-dev` and `libudev-dev`. A first run also needs JDK 25 and the user's own
Minecraft install; see the README.

## Build inputs you must not delete

These look like tests or leftovers and are not:

- `tools/native-hook-fragments/` — read by `horizon-mod-api-gen/src/build.rs`; missing means every
  client build fails.
- `native-hooks.json` and `crates/horizon-client/src/mod_api.rs` — parsed/generated on every build.
- `packaging/icons/horizon.ico` — Windows resource and the 8 MB stack link argument.
- `mods/horizon/src/test/java/` — the Java exporters `horizon-prepare` compiles. Not a test suite.
- `tests/fixtures/*.json` — `include_str!`-ed by the client test target.
- `third_party/{wgpu-hal,libmimalloc-sys}` — real runtime fixes; see `THIRD_PARTY_NOTICES.md`.
  `third_party/naga` stays until the shader-pack cut lands.

## Style

- Match the surrounding code. This tree mirrors vanilla's structure on purpose; do not "clean up"
  Java-shaped loops in `horizon-world`.
- No hardcoded user-facing strings: use translation keys (`Text::tr`, `lang::get`).
- Delete code, do not add a second feature matrix. Cargo features are additive; a `lite` feature
  that turns everything off rots into an unbuildable combination.
- One subsystem per commit. The gate is `cargo check --workspace --all-targets`, not a green CI
  badge you did not watch.

## What we lost

The upstream differential harnesses are gone: 569 Python tests and the Java oracles that compared
every behaviour against the real 26.3 jars. We cannot prove parity any more. The audits in
`docs/lite/reports/` are the map; treat gameplay changes with corresponding care, and prefer
keeping vanilla behaviour over clever rewrites.
