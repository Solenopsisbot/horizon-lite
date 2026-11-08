# Contributing to Horizon Lite

This is an unofficial fork of Horizon. It is maintained on a best-effort basis and is **not**
affiliated with or supported by the upstream project. Please do not send upstream issues or pull
requests about this repository.

## What fits

- Bug fixes that keep vanilla 26.3 behaviour.
- Build and portability fixes.
- Removing a subsystem listed in [`docs/lite/PLAN.md`](docs/lite/PLAN.md), one subsystem per
  commit, with `cargo check --workspace --all-targets` green.
- Documentation that describes what the code actually does.

## What does not fit

- Re-adding the launcher, Realms, telemetry upload, a mod registry, a dedicated-server supervisor,
  release signing, or an auto-updater pointed at upstream releases.
- A `lite` cargo feature that turns existing code off instead of deleting it.
- Gameplay rewrites that break vanilla saves, block/item IDs, or same-seed world generation.

## Before a pull request

```sh
cargo fmt --all
cargo check --workspace --all-targets
cargo check -p horizon-client --no-default-features
cargo test -p horizon-client --lib
```

Say which subsystem the change belongs to and paste the check result. If you touched gameplay,
say which vanilla behaviour it preserves and how you know.

## License

By contributing you agree that your changes are licensed under the MIT license in `LICENSE`.
Keep `NOTICE` and `THIRD_PARTY_NOTICES.md` accurate.
