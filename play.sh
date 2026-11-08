#!/usr/bin/env bash
# Play a world with the release build.
#
#   ./play.sh                 # world "World"
#   ./play.sh MyWorld         # world "MyWorld"
#   ./play.sh MyWorld --creative
#
# The first run needs the resources built from your own Minecraft 26.3 install:
#   ./target/release/horizon-prepare --prepare --server-jar ~/Downloads/server.jar
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
resources="$root/.local/horizon-client/26.3"
binary="$root/target/release/horizon-client"
world="${1:-World}"
shift || true

if [[ ! -x "$binary" ]]; then
    echo "horizon-client is not built. Run:" >&2
    echo "  cargo build --release -p horizon-client -p horizon-prepare" >&2
    exit 1
fi

if [[ ! -d "$resources" ]]; then
    echo "Prepared resources are missing: $resources" >&2
    echo "Prepare them once from your own Minecraft 26.3 install (needs JDK 25):" >&2
    echo "  $root/target/release/horizon-prepare --prepare --server-jar ~/Downloads/server.jar" >&2
    exit 1
fi

# Keep logs, crash reports and caches out of the repository root.
game_dir="${HORIZON_LITE_GAME_DIR:-$root/.local/game}"
mkdir -p "$game_dir"

exec "$binary" --resources "$resources" --game-dir "$game_dir" --world "$world" "$@"
