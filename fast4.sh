#!/usr/bin/env bash
# fast4.sh — build linux64-nonfree, linux64-nonfree-shared, win64-nonfree,
# win64-nonfree-shared for FFmpeg 9.0 by reusing BtbN's prebuilt gpl-shared
# images from ghcr.io instead of recompiling all 120 dependencies.
#
# Strategy (Option A):
#   The published gpl-shared images already contain the full toolchain AND
#   all 120 third-party deps installed under /opt/ffbuild/. The only
#   difference between "gpl" and "nonfree" is one extra dep (fdk-aac) and
#   the --enable-nonfree / --enable-libfdk-aac configure flags.
#
#   For each nonfree target we:
#     1. Pull linux64-gpl-shared-9.0:latest (or win64-gpl-shared-9.0:latest).
#        Note the naming: BtbN encodes the FFmpeg version into the image
#        NAME (e.g. linux64-gpl-shared-9.0), not the docker tag — every
#        variant shares the `:latest` tag and is overwritten on each
#        publish. See .github/workflows/build.yml:264,289.
#     2. Build a thin overlay image that starts FROM that gpl-shared image,
#        builds fdk-aac into /opt/ffbuild/, and bakes in the nonfree
#        FF_CONFIGURE. This is the entire dep work — ~5 min instead of ~2 h.
#     3. Run that overlay image to configure+build+install ffmpeg into
#        /ffbuild/prefix and package the artifacts.
#     4. Tag the running image as the final linux64-nonfree(-shared):9.0.
#
#   No 30-60 min crosstool-NG rebuild, no 120 dep rebuilds.
#
# Usage:
#   ./fast4.sh                      # all four targets
#   ./fast4.sh linux64              # only the linux64 pair
#   ./fast4.sh win64 nonfree-shared # one specific target+variant
#
# Env vars (same as fast3.sh for muscle-memory consistency):
#   FAST3_NO_HOST_NET=1        Skip --driver-opt network=host.
#   FAST3_PARALLELISM=N        Override buildkit max-parallelism (cap 4).
#   FAST3_KEEP_CACHES=0        Delete .cache/ and the builder on exit.
#
# Notes:
#   - Disk: budget ~20 GB. Most space is the pulled gpl-shared images
#     (~1.3 GB each on disk after pull, two of them).
#   - The "shared" variants don't need a different gpl base — we just add
#     --enable-shared --disable-static to FF_CONFIGURE on top of the same
#     gpl-shared image, which is fine because /opt/ffbuild/ contains both
#     static and shared libs in the gpl-shared image.

set -euo pipefail
cd "$(dirname "$0")"

BUILDER_NAME="ffbuilder"
FFVER="8.1"
PUBLIC_REGISTRY="ghcr.io"
PUBLIC_REPO="btbn/ffmpeg-builds"

# Order chosen so the cached deps from each shared build warm the static
# build (both pull from the same gpl-shared base image, so layer reuse is
# high; build order doesn't actually matter for the build itself, only
# for log readability).
ALL_TARGETS=(
    "linux64 nonfree-shared"
    "linux64 nonfree"
    "win64   nonfree-shared"
    "win64   nonfree"
)

# Map (target,variant) -> base gpl-shared image ref to pull from ghcr.io.
# BtbN's published naming is `<target>-<variant>-<ffver>:latest`, e.g.
# `linux64-gpl-shared-9.0:latest`. The FFmpeg version is part of the
# image NAME, not the tag — every variant shares the `:latest` tag.
# All four nonfree variants share a single gpl-shared base per target —
# the difference is just the configure flags, baked into the overlay.
declare -A GPL_BASE=(
    ["linux64 nonfree"]="linux64-gpl-shared-${FFVER}:latest"
    ["linux64 nonfree-shared"]="linux64-gpl-shared-${FFVER}:latest"
    ["win64 nonfree"]="win64-gpl-shared-${FFVER}:latest"
    ["win64 nonfree-shared"]="win64-gpl-shared-${FFVER}:latest"
)

detect_parallelism() {
    local n
    n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 2)"
    # Cap at 4 by default: each dep compile is fs-heavy and on virtualised
    # disks (qcow2/VMDK) more parallelism just thrashes the disk. Override
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

    local -a cmd=(
        docker buildx create --bootstrap --name "$BUILDER_NAME"
        --config "$tmpcfg"
    )
    for opt in "${driver_opts[@]}"; do
        cmd+=( --driver-opt "$opt" )
    done
    "${cmd[@]}"
}

# Pull both gpl-shared base images once. Skipped silently if already present.
# These are the bulk of the speedup — all 120 deps live in these layers.
# BtbN's naming is `<target>-<variant>-<ffver>:latest` (version in the NAME,
# not the tag — every variant shares the `:latest` tag), per
# .github/workflows/build.yml:264,289.
pull_gpl_bases() {
    local ref
    for ref in \
        "${PUBLIC_REGISTRY}/${PUBLIC_REPO}/linux64-gpl-shared-${FFVER}:latest" \
        "${PUBLIC_REGISTRY}/${PUBLIC_REPO}/win64-gpl-shared-${FFVER}:latest"; do
        echo ">>> pulling $ref"
        if ! docker pull "$ref"; then
            echo "    WARNING: failed to pull $ref."
            echo "    If you are behind an auth proxy, run 'docker login ${PUBLIC_REGISTRY}' and retry."
        fi
    done
}

# Clone fdk-aac once — it's the only nonfree-specific dep. The source is
# mounted into the Docker build (via --mount) so it's available for compilation.
prepare_fdk_aac_source() {
    local src_dir="${PWD}/.cache/fdk-aac-src"
    local commit="d8e6b1a3aa606c450241632b64b703f21ea31ce3"
    if [[ -d "${src_dir}/.git" ]]; then
        echo ">>> fdk-aac source already cloned (checked)"
        return 0
    fi
    echo ">>> cloning fdk-aac source (commit ${commit}) to .cache/fdk-aac-src"
    mkdir -p "${src_dir}"
    git clone --filter=blob:none https://github.com/mstorsjo/fdk-aac.git "${src_dir}"
    git -C "${src_dir}" checkout "${commit}"
}

check_disk() {
    local need_kb=20000000  # ~20 GB
    local avail_kb
    avail_kb="$(df -Pk "${PWD}/.cache" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [[ -z "$avail_kb" ]]; then return 0; fi
    if (( avail_kb < need_kb )); then
        echo ">>> WARNING: only ${avail_kb} KB free in $(dirname "${PWD}/.cache")"
        echo "    (recommended: >= $((need_kb/1000000)) GB). Continuing anyway."
    fi
}

# Build the FF_CONFIGURE flags for a given nonfree variant. Starts from the
# gpl-shared defaults used by BtbN's published image (so we match the
# dependency set that's already installed in the base), then adds --enable-
# nonfree and --enable-libfdk-aac.
build_ff_configure() {
    local variant=$1
    local cfg

    # Common gpl-shared flags — must match what's in BtbN's published
    # linux64-gpl-shared-9.0 / win64-gpl-shared-9.0 image (or the closest
    # published FFmpeg version if 9.0 isn't yet on the registry) so the
    # deps it already has satisfy ./configure.
    cfg="--enable-gpl --enable-version3 --disable-debug --disable-w32threads --enable-pthreads"
    cfg+=" --enable-iconv --enable-zlib --enable-libxml2 --enable-libvmaf"
    cfg+=" --enable-fontconfig --enable-libharfbuzz --enable-libfreetype --enable-libfribidi"
    cfg+=" --enable-vulkan --enable-libvorbis --disable-libxcb --disable-xlib"
    cfg+=" --disable-libpulse --enable-gmp --enable-lzma --enable-liblcevc-dec"
    cfg+=" --enable-opencl --enable-amf --enable-libaom --enable-libaribb24"
    cfg+=" --enable-avisynth --enable-chromaprint --enable-libdav1d --enable-libdavs2"
    cfg+=" --enable-libdvdread --enable-libdvdnav --enable-ffnvcodec --enable-cuda-llvm"
    cfg+=" --enable-frei0r --enable-libgme --enable-libkvazaar --enable-libaribcaption"
    cfg+=" --enable-libass --enable-libbluray --enable-libjxl --enable-libmp3lame"
    cfg+=" --enable-libopus --enable-libplacebo --enable-librist --enable-libssh"
    cfg+=" --enable-libtheora --enable-libvpx --enable-libwebp --enable-libzmq"
    cfg+=" --enable-lv2 --enable-libvpl --enable-openal --enable-liboapv"
    cfg+=" --enable-libopencore-amrnb --enable-libopencore-amrwb --enable-libopenh264"
    cfg+=" --enable-libopenjpeg --enable-libopenmpt --enable-librav1e"
    cfg+=" --enable-librubberband --enable-schannel --enable-sdl2 --enable-libsnappy"
    cfg+=" --enable-libsoxr --enable-libsrt --enable-libsvtav1 --enable-libtwolame"
    cfg+=" --enable-libuavs3d --disable-libdrm --enable-vaapi --enable-libvidstab"
    cfg+=" --enable-libvvenc --disable-whisper --enable-libx264 --enable-libx265"
    cfg+=" --enable-libxavs2 --enable-libxvid --enable-libzimg --enable-libzvbi"

    # Nonfree additions.
    cfg+=" --enable-nonfree --enable-libfdk-aac"

    # Static vs shared. For the "nonfree" variant we want static ffmpeg,
    # matching gpl (the gpl-shared image's deps support both).
    if [[ "$variant" == *-shared ]]; then
        cfg+=" --enable-shared --disable-static"
    else
        cfg+=" --disable-shared --enable-static"
    fi

    echo "$cfg"
}

# Build the overlay image for a (target, variant). This:
#   1. Starts FROM the gpl-shared image (skips crosstool-NG and all 120 deps).
#   2. Builds fdk-aac into /opt/ffbuild/ (the one missing dep).
#   3. Bakes FF_CONFIGURE + FF_CFLAGS + FF_LDFLAGS + FF_LIBS env so a
#      `docker run` on the resulting image can drive configure+make directly
#      without any host-side vars.sh / Dockerfile regeneration.
#
# Writes the overlay Dockerfile to .cache/Dockerfile.nonfree.<target>-<variant>
# so it's inspectable after the run.
build_overlay() {
    local target=$1 variant=$2
    local key="${target} ${variant}"
    local base_ref="${GPL_BASE[$key]}"
    local overlay_tag="${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${target}-${variant}:${FFVER}"
    local dockerfile=".cache/Dockerfile.nonfree.${target}-${variant}"
    local ff_cfg

    ff_cfg="$(build_ff_configure "$variant")"

    mkdir -p .cache
    echo
    echo "============================================================"
    echo "  Building overlay: ${target} ${variant} (FFmpeg ${FFVER})"
    echo "  Base: ${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${base_ref}"
    echo "  Tag:  ${overlay_tag}"
    echo "============================================================"

    cat >"$dockerfile" <<EOF
# Auto-generated by fast4.sh — do not edit.
# Starts FROM the published gpl-shared image (all 120 deps already at
# /opt/ffbuild/) and adds fdk-aac, the only nonfree-specific dep.
FROM ${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${base_ref}

# fdk-aac source — pinned commit matches scripts.d/50-fdk-aac.sh upstream.
source scripts.d/50-fdk-aac.sh
ARG FDK_AAC_COMMIT
RUN --mount=src=.cache/fdk-aac-src,dst=/src,rw \
    set -eux; \
    if [[ ! -d /src/.git ]]; then \
        git clone --filter=blob:none https://github.com/mstorsjo/fdk-aac.git /src; \
        git -C /src checkout "\$FDK_AAC_COMMIT"; \
    fi; \
    cd /src; \
    ./autogen.sh; \
    ./configure --prefix="\$FFBUILD_PREFIX" --disable-shared --enable-static --with-pic --disable-example \
        --host="\$FFBUILD_TOOLCHAIN"; \
    make -j\$(nproc); \
    make install; \
    rm -rf /src

# Bake the FFmpeg configure flags. Static vs shared is already encoded in
# FF_CONFIGURE. FF_CFLAGS/FF_LDFLAGS/FF_LIBS match what upstream uses in
# the generated Dockerfile for the equivalent nonfree variant.
ENV FF_CONFIGURE="${ff_cfg}" \\
    FF_CFLAGS="-DLIBTWOLAME_STATIC" \\
    FF_CXXFLAGS="" \\
    FF_LDFLAGS="-pthread" \\
    FF_LDEXEFLAGS="" \\
    FF_LIBS="-lgomp" \\
    GIT_BRANCH="release/${FFVER}"
EOF

    docker buildx --builder "$BUILDER_NAME" build \
        --cache-from "type=registry,ref=${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${base_ref}" \
        --cache-to   "type=local,mode=max,dest=.cache/${overlay_tag//\//_}" \
        --load --tag "$overlay_tag" \
        --file "$dockerfile" \
        .
}

# Drive the configure+make+install inside the overlay image. Mirrors what
# build.sh does for the upstream-generated Dockerfile, but skips the host-
# side vars.sh/variants dance because FF_CONFIGURE is already baked in.
run_ffmpeg_build() {
    local target=$1 variant=$2
    local overlay_tag="${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${target}-${variant}:${FFVER}"
    local build_script=".cache/build-ffmpeg.${target}-${variant}.sh"

    echo
    echo ">>> building ffmpeg inside $overlay_tag"

    # Pick the right FFmpeg branch matching the addin.
    local git_branch="release/${FFVER}"

    cat >"$build_script" <<EOF
#!/bin/bash
set -xe
cd /ffbuild
rm -rf ffmpeg prefix

git clone --filter=blob:none --branch='${git_branch}' https://github.com/FFmpeg/FFmpeg.git ffmpeg
cd ffmpeg

./configure --prefix=/ffbuild/prefix --pkg-config-flags="--static" \$FFBUILD_TARGET_FLAGS \$FF_CONFIGURE \\
    --extra-cflags="\$FF_CFLAGS" --extra-cxxflags="\$FF_CXXFLAGS" --extra-libs="\$FF_LIBS" \\
    --extra-ldflags="\$FF_LDFLAGS" --extra-ldexeflags="\$FF_LDEXEFLAGS" \\
    --cc="\$CC" --cxx="\$CXX" --ar="\$AR" --ranlib="\$RANLIB" --nm="\$NM" \\
    --extra-version="\$(date +%Y%m%d)" || { cat ffbuild/config.log; exit 1; }
make -j\$(nproc)
make install install-doc
EOF

    # UID mapping (skip under rootless docker).
    local -a uidargs=()
    if ! docker info -f '{{println .SecurityOptions}}' | grep rootless >/dev/null 2>&1; then
        uidargs=( -u "$(id -u):$(id -g)" )
    fi
    local tty_arg=""
    [[ -t 1 ]] && tty_arg="-t"

    mkdir -p .cache/ffbuild-output/${target}-${variant}
    docker run --rm -i $tty_arg "${uidargs[@]}" \
        -v "${PWD}/.cache/ffbuild-output/${target}-${variant}":/ffbuild \
        -v "${PWD}/${build_script}":/build.sh \
        "$overlay_tag" \
        bash /build.sh
}

cleanup_caches() {
    if [[ "${FAST3_KEEP_CACHES:-1}" == "1" ]]; then
        echo ">>> leaving .cache/ and the builder in place (FAST3_KEEP_CACHES=1)"
        return 0
    fi
    echo ">>> removing .cache/ and the buildkit builder"
    rm -rf "${PWD}/.cache" || true
    docker buildx rm -f "$BUILDER_NAME" 2>/dev/null || true
}

main() {
    local only_target="${1:-}"
    local only_variant="${2:-}"

    mkdir -p .cache
    check_disk
    create_builder
    pull_gpl_bases
    prepare_fdk_aac_source

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

        build_overlay "$target" "$variant"
        run_ffmpeg_build "$target" "$variant"
    done

    cleanup_caches

    echo
    echo ">>> all requested builds complete"
    echo ">>> built images:"
    docker images --filter "reference=${PUBLIC_REGISTRY}/${PUBLIC_REPO}/*nonfree*${FFVER}*" \
        --format "    {{.Repository}}:{{.Tag}}  ({{.Size}})" || true
    echo
    echo ">>> ffmpeg binaries:"
    find .cache/ffbuild-output -name ffmpeg -o -name ffmpeg.exe 2>/dev/null \
        | sed 's/^/    /' || true
}

main "$@"
