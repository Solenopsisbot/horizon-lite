# Documentation

Most of the upstream documentation described product surfaces this fork removed. What remains
describes code that is still here.

## Start here

- [`lite/PLAN.md`](lite/PLAN.md) — what Horizon Lite is, what was removed, what is still cuttable,
  and the traps.
- [`lite/STATUS.md`](lite/STATUS.md) — verified build state and known gaps.
- [`lite/reports/`](lite/reports/) — nine read-only subsystem audits of upstream `4e6920a`.
- [`architecture.md`](architecture.md) — feature → files → checks for the game loop and each
  subsystem that changes most often.

## Game and client

- [`native-client.md`](native-client.md) — options, controls, running the client.
- [`horizon-ctl-commands.md`](horizon-ctl-commands.md) — the headless control tool.
- [`build-times.md`](build-times.md), [`profiling.md`](profiling.md) — build and profile.
- [`versioning.md`](versioning.md) — the pinned Minecraft version.

## World and simulation

- [`world-generation.md`](world-generation.md), [`world-data.md`](world-data.md),
  [`world-height.md`](world-height.md)
- [`noise-generation.md`](noise-generation.md), [`density-functions.md`](density-functions.md),
  [`heightmaps.md`](heightmaps.md)
- [`carving.md`](carving.md), [`terrain-filling.md`](terrain-filling.md),
  [`feature-placement.md`](feature-placement.md), [`structure-density.md`](structure-density.md)
- [`biome-lookup.md`](biome-lookup.md), [`biome-temperatures.md`](biome-temperatures.md)
- [`block-state-codecs.md`](block-state-codecs.md), [`collision-geometry.md`](collision-geometry.md),
  [`material-conditions.md`](material-conditions.md),
  [`material-rule-libraries.md`](material-rule-libraries.md),
  [`material-surfaces.md`](material-surfaces.md)
- [`scheduled-ticks.md`](scheduled-ticks.md), [`value-providers.md`](value-providers.md),
  [`vertical-anchors.md`](vertical-anchors.md), [`datapack-upgrade.md`](datapack-upgrade.md)

## Rendering

- [`graphics.md`](graphics.md) — renderer, backends, presets.
- [`face-visibility.md`](face-visibility.md), [`visibility-benchmark.md`](visibility-benchmark.md)
- [`prepare-performance.md`](prepare-performance.md) — making `horizon-prepare` fast.

## Server-side (still used by single player)

- [`server-levels.md`](server-levels.md) — one level per dimension on the server thread.
- [`velocity-forwarding.md`](velocity-forwarding.md) — proxy handshake, LAN/dedicated only.

The upstream docs for the launcher, Realms, telemetry, mod registry, shader packs, dedicated
hosting and parity workflows were deleted with the code they described. They remain in the
upstream repository and in the audit reports.
