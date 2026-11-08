#!/usr/bin/env bash
# Build the fastest binary this machine can run.
#
#   scripts/build-speed.sh            # fat LTO + target-cpu=native
#   scripts/build-speed.sh --pgo      # ...and profile-guided optimisation
#
# The output is target/lite/horizon-client. `--pgo` needs a working GPU (or
# Xvfb) and a prepared resource tree, because it trains on the real benchmark;
# see docs/lite/PERFORMANCE.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

pgo=0
[[ "${1:-}" == "--pgo" ]] && pgo=1

# Native tuning only for the target this machine actually is. Remove this (or
# build for a generic target) if the binary has to run on another CPU.
native_flag=()
case "$(uname -m)" in
    x86_64) native_flag=(-C target-cpu=native) ;;
    aarch64) native_flag=(-C target-cpu=native) ;;
esac

if [[ $pgo -eq 1 ]]; then
    resources="${HORIZON_LITE_RESOURCES:-$root/.local/horizon-client/26.3}"
    if [[ ! -d "$resources" ]]; then
        echo "PGO needs prepared resources at $resources (set HORIZON_LITE_RESOURCES)" >&2
        exit 1
    fi
    profdir="$root/target/pgo-data"
    rm -rf "$profdir" && mkdir -p "$profdir"
    echo "== instrumented build =="
    RUSTFLAGS="${native_flag[*]} -Cprofile-generate=$profdir" \
        cargo build --profile lite-pgo -p horizon-client
    binary="$root/target/lite-pgo/horizon-client"
    echo "== training run 1: title screen and menus =="
    scratch="$(mktemp -d /tmp/horizon-lite-pgo.XXXXXX)"
    (
        cd "$scratch"
        HORIZON_HOME="$scratch/home" \
        HORIZON_NO_AUDIO=1 \
        HORIZON_NO_DISCORD=1 \
        HORIZON_NO_HEARTBEAT=1 \
            "$binary" --resources "$resources" --game-dir "$scratch/game" --frames 900 || true
    )
    echo "== training run 2: benchmark standard =="
    (
        cd "$scratch"
        HORIZON_HOME="$scratch/home" \
        HORIZON_NO_AUDIO=1 \
        HORIZON_NO_DISCORD=1 \
        HORIZON_NO_HEARTBEAT=1 \
            "$binary" \
                --resources "$resources" \
                --game-dir "$scratch/game" \
                --benchmark standard
    )
    echo "== merging profiles =="
    profdata="$(command -v llvm-profdata || true)"
    if [[ -z "$profdata" ]]; then
        host="$(rustc -vV | sed -n 's/^host: //p')"
        profdata="$(rustc --print sysroot)/lib/rustlib/$host/bin/llvm-profdata"
    fi
    "$profdata" merge -o "$profdir/merged.profdata" "$profdir"
    echo "== optimised build =="
    RUSTFLAGS="${native_flag[*]} -Cprofile-use=$profdir/merged.profdata -Cllvm-args=-pgo-warn-missing-function" \
        cargo build --profile lite -p horizon-client
    echo "built target/lite/horizon-client with PGO profiles from $profdir"
else
    RUSTFLAGS="${native_flag[*]}" cargo build --profile lite -p horizon-client
    echo "built target/lite/horizon-client"
fi
