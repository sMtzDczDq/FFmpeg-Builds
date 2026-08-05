#!/usr/bin/env bash
# fast3.sh — build linux64-nonfree, linux64-nonfree-shared, win64-nonfree,
# win64-nonfree-shared for FFmpeg 9.0 by reusing BtbN's prebuilt base images
# and registry-layer cache from a local VM (no GitHub Actions).
#
# What this gives you over ./makeimage.sh directly:
#   - Pulls ghcr.io/btbn/ffmpeg-builds/base-{linux64,win64}:latest, skipping
#     the 30-60 min crosstool-NG toolchain build.
#   - Iterates all four targets in one invocation, keeping the buildkit
#     builder and .cache warm across them (NOCLEAN=1).
#   - Honours BtbN's cache layout so --cache-from finds warm layers from the
#     GPL published images.
#   - Tunes buildkit parallelism for local VMs (not GitHub runner defaults).
#
# Usage:   ./fast3.sh                 # build all four
#          ./fast3.sh linux64         # build only linux64 pair
#          ./fast3.sh win64 nonfree   # build only win64-nonfree
#
# Notes for VM usage:
#   - Set FAST3_NO_HOST_NET=1 if your VM/docker setup rejects
#     --driver-opt network=host (macOS Docker Desktop, Lima/Colima, many
#     nested-virt setups). Falls back to default bridge networking.
#   - Set FAST3_PARALLELISM=N to override buildkit parallelism (default: 4,
#     capped from nproc). Cap is conservative because FFmpeg dep builds are
#     fs-heavy and lock up virtualised disks above ~4 concurrent stages.
#   - Set FAST3_KEEP_CACHES=0 to delete .cache/images/* on exit (default 1).
#   - Disk: budget ~50 GB for .cache/ across a full four-image run.

set -euo pipefail
cd "$(dirname "$0")"

BUILDER_NAME="ffbuilder"
FFVER="9.0"
PUBLIC_REGISTRY="ghcr.io"
PUBLIC_REPO="btbn/ffmpeg-builds"

# Order chosen so each target's cache pull from a similar published cache
# gives the most hits. Shared builds first (matching gpl-shared:cache),
# static builds after (matching gpl:cache).
ALL_TARGETS=(
    "linux64 nonfree-shared"
    "win64   nonfree-shared"
    "linux64 nonfree"
    "win64   nonfree"
)

detect_parallelism() {
    local n
    n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)"
    # Cap at 4 by default: each FFmpeg dep compile is fs-heavy (lots of
    # small objects, repeated tarball extraction) and on virtualised disks
    # (qcow2, VMDK, etc.) more parallelism just thrashes the disk. Override
    # via FAST3_PARALLELISM=N.
    if [[ "$n" -gt 4 ]]; then n=4; fi
    echo "$n"
}

create_builder() {
    if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
        echo ">>> buildx builder '$BUILDER_NAME' already exists, reusing"
        return 0
    fi

    local parallelism="${FAST3_PARALLELISM:-$(detect_parallelism)}"
    echo ">>> creating buildx builder '$BUILDER_NAME' (parallelism=$parallelism)"

    # Build a per-instance buildkit config so we don't have to edit the
    # repo-tracked file. The original .github/buildkit.toml caps at 2 which
    # is tuned for GitHub Actions runners.
    local tmpcfg
    tmpcfg="$(mktemp --suffix=.toml)"
    trap 'rm -f "$tmpcfg"' RETURN

    cat >"$tmpcfg" <<EOF
[worker.oci]
  max-parallelism = ${parallelism}
EOF

    local -a driver_opts=(
        "env.BUILDKIT_STEP_LOG_MAX_SIZE=-1"
        "env.BUILDKIT_STEP_LOG_MAX_SPEED=-1"
    )
    if [[ "${FAST3_NO_HOST_NET:-0}" != "1" ]]; then
        driver_opts+=( "network=host" )
    fi

    # Build the docker create command piece by piece so each --driver-opt
    # becomes its own argv element. "${driver_opts[@]}" with enclosing
    # double-quotes would join them on IFS (a space) into a single argv,
    # which is exactly the bug that broke earlier: docker then sees one
    # --driver-opt "a b c" instead of three.
    local -a cmd=(
        docker buildx create --bootstrap --name "$BUILDER_NAME"
        --config "$tmpcfg"
    )
    for opt in "${driver_opts[@]}"; do
        cmd+=( --driver-opt "$opt" )
    done

    "${cmd[@]}"
}

pull_bases() {
    echo ">>> pulling published base images (skips crosstool-NG / mingw rebuild)"
    if ! docker pull "${PUBLIC_REGISTRY}/${PUBLIC_REPO}/base-linux64:latest"; then
        echo "    WARNING: failed to pull base-linux64. If you are behind an"
        echo "    auth proxy, run 'docker login ghcr.io' and retry."
    fi
    if ! docker pull "${PUBLIC_REGISTRY}/${PUBLIC_REPO}/base-win64:latest"; then
        echo "    WARNING: failed to pull base-win64."
    fi
}

# Disk-space guard. A full four-image run needs roughly 30-50 GB free.
check_disk() {
    local need_kb=30000000  # ~30 GB
    local avail_kb
    avail_kb="$(df -Pk "${PWD}/.cache" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -z "$avail_kb" ]]; then return 0; fi
    if (( avail_kb < need_kb )); then
        echo ">>> WARNING: only ${avail_kb} KB free in $(dirname "${PWD}/.cache")"
        echo "    (recommended: >= $((need_kb/1000000)) GB). Continuing anyway."
    fi
}

# Run makeimage.sh once for a given target/variant. makeimage.sh consumes
# positional args via util/vars.sh (TARGET, VARIANT, [addin]...). The
# QUICKBUILD env var forces it to skip its own base-image build loop and
# use the pulled base images via --build-context. NOCLEAN keeps the
# buildkit builder and .cache/images around between iterations.
build_one() {
    local target=$1 variant=$2
    echo
    echo "============================================================"
    echo "  Building: ${target} ${variant} (FFmpeg ${FFVER})"
    echo "============================================================"

    QUICKBUILD=1 NOCLEAN=1 \
        ./makeimage.sh "$target" "$variant" "$FFVER"
}

cleanup_caches() {
    if [[ "${FAST3_KEEP_CACHES:-1}" == "1" ]]; then
        echo ">>> leaving .cache/ in place (FAST3_KEEP_CACHES=1)"
        return 0
    fi
    echo ">>> removing .cache/images and the buildkit builder"
    rm -rf "${PWD}/.cache/images" || true
    docker buildx rm -f "$BUILDER_NAME" 2>/dev/null || true
}

main() {
    local only_target="${1:-}"
    local only_variant="${2:-}"

    mkdir -p .cache
    check_disk
    create_builder
    pull_bases

    # Re-export FFVER so subshells inherit it; makeimage.sh only consumes it
    # via its argv form, but the env var is harmless and useful for logs.
    export FFVER

    for entry in "${ALL_TARGETS[@]}"; do
        # shellcheck disable=SC2086
        set -- $entry
        local target=$1 variant=$2

        if [[ -n "$only_target" && "$target" != "$only_target" ]]; then
            continue
        fi
        if [[ -n "$only_variant" && "$variant" != "$only_variant" ]]; then
            continue
        fi

        build_one "$target" "$variant"
    done

    cleanup_caches

    echo
    echo ">>> all requested builds complete"
    echo ">>> built images:"
    docker images --filter "reference=${PUBLIC_REGISTRY}/${PUBLIC_REPO}/*nonfree*${FFVER}*" \
        --format "    {{.Repository}}:{{.Tag}}  ({{.Size}})" || true
}

main "$@"
