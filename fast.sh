#!/usr/bin/env bash
# fast.sh — build linux64-nonfree, linux64-nonfree-shared, win64-nonfree,
# win64-nonfree-shared for the latest released FFmpeg by reusing BtbN's
# prebuilt gpl-shared images from ghcr.io instead of recompiling all 120
# dependencies. The release version is auto-detected from ffmpeg.org
# (9.0.2 -> release branch 9.0); pin it with FAST_FFVER if needed.
#
# Strategy (Option A):
#   The published gpl-shared images already contain the full toolchain AND
#   all 120 third-party deps installed under /opt/ffbuild/. The only
#   difference between "gpl" and "nonfree" is one extra dep (fdk-aac) and
#   the --enable-nonfree / --enable-libfdk-aac configure flags.
#
#   For each nonfree target we:
#     1. Pull linux64-gpl-shared-<ffver>:latest (or win64-gpl-shared-<ffver>:latest).
#        Note the naming: BtbN encodes the FFmpeg version into the image
#        NAME (e.g. linux64-gpl-shared-9.0), not the docker tag — every
#        variant shares the `:latest` tag and is overwritten on each
#        publish. See .github/workflows/build.yml:264,289.
#     2. Build a thin overlay image that starts FROM that gpl-shared image,
#        builds fdk-aac into /opt/ffbuild/, and bakes in the nonfree
#        FF_CONFIGURE. This is the entire dep work — ~5 min instead of ~2 h.
#     3. Run that overlay image to configure+build+install ffmpeg into
#        /ffbuild/prefix and package the artifacts.
#     4. Tag the running image as the final linux64-nonfree(-shared):<ffver>.
#
#   No 30-60 min crosstool-NG rebuild, no 120 dep rebuilds.
#
# Usage:
#   ./fast.sh                      # all four targets
#   ./fast.sh linux64              # only the linux64 pair
#   ./fast.sh win64 nonfree-shared # one specific target+variant
#
# Env vars:
#   FAST_FFVER=x.y            Pin the FFmpeg release branch (default: detect newest from ffmpeg.org).
#   FAST_NO_HOST_NET=1        Skip --driver-opt network=host.
#   FAST_PARALLELISM=N        Override buildkit max-parallelism (cap 4).
#   FAST_KEEP_CACHES=0        Delete .cache/ and the builder on exit.
#
# Notes:
#   - Disk: budget ~20 GB. Most space is the pulled gpl-shared images
#     (~1.3 GB each on disk after pull, two of them).
#   - The "shared" variants don't need a different gpl base — we just add
#     --enable-shared --disable-static to FF_CONFIGURE on top of the same
#     gpl-shared image, which is fine because /opt/ffbuild/ contains both
#     static and shared libs in the gpl-shared image.
#   - Each build is packaged into artifacts/ as
#     ffmpeg-<version>-<target>-<variant>.zip (win) or .tar.xz (linux),
#     matching build.sh's naming and layout. The directory *inside* the
#     archive is shortened to ffmpeg-<base-version> (e.g. ffmpeg-n9.0.2),
#     and the Linux packages additionally contain an install.sh that installs
#     the build into /usr/local.

set -euo pipefail
cd "$(dirname "$0")"

BUILDER_NAME="ffbuilder"
FFVER="9.0"  # fallback only — normally auto-detected in main()
PUBLIC_REGISTRY="ghcr.io"
PUBLIC_REPO="btbn/ffmpeg-builds"

# Order chosen so the cached deps from each shared build warm the static
# build (both pull from the same gpl-shared base image, so layer reuse is
# high; build order doesn't actually matter for the build itself, only
# for log readability).
# Flat list of target/variant pairs, consumed two at a time.
ALL_TARGETS=(
    linux64   nonfree-shared
    linux64   nonfree
    win64     nonfree-shared
    win64     nonfree
)

# Map (target,variant) -> base gpl-shared image ref to pull from ghcr.io.
# BtbN's published naming is `<target>-<variant>-<ffver>:latest`, e.g.
# `linux64-gpl-shared-9.0:latest`. The FFmpeg version is part of the
# image NAME, not the tag — every variant shares the `:latest` tag.
# All four nonfree variants share a single gpl-shared base per target —
# the difference is just the configure flags, baked into the overlay.
# GPL_BASE is populated in main() once FFVER has been resolved, since its
# values embed ${FFVER}.
declare -A GPL_BASE=()

detect_parallelism() {
    local N
    N="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || printf '%s\n' 2)"
    # Cap at 4 by default: each dep compile is fs-heavy and on virtualised
    # disks (qcow2/VMDK) more parallelism just thrashes the disk. Override
    # via FAST_PARALLELISM=N.
    if (( N > 4 )); then N=4; fi
    printf '%s\n' "$N"
}

create_builder() {
    if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
        echo ">>> buildx builder '$BUILDER_NAME' already exists, reusing"
        return 0
    fi

    local PARALLELISM="${FAST_PARALLELISM:-$(detect_parallelism)}"
    echo ">>> creating buildx builder '$BUILDER_NAME' (parallelism=$PARALLELISM)"

    local TMPCFG
    TMPCFG="$(mktemp --suffix=.toml)"
    trap 'rm -f "$TMPCFG"' RETURN

    cat >"$TMPCFG" <<EOF
[worker.oci]
  max-parallelism = ${PARALLELISM}
EOF

    local -a DRIVER_OPTS=(
        "env.BUILDKIT_STEP_LOG_MAX_SIZE=-1"
        "env.BUILDKIT_STEP_LOG_MAX_SPEED=-1"
    )
    if [[ "${FAST_NO_HOST_NET:-0}" != "1" ]]; then
        DRIVER_OPTS+=( "network=host" )
    fi

    local -a CMD=(
        docker buildx create --bootstrap --name "$BUILDER_NAME"
        --config "$TMPCFG"
    )
    for OPT in "${DRIVER_OPTS[@]}"; do
        CMD+=( --driver-opt "$OPT" )
    done
    "${CMD[@]}"
}

# Numeric compare for dotted version strings (x.y.z) without relying on
# `sort -V` (BSD sort on macOS lacks it). Returns 0 if $1 >= $2.
ffver_ge() {
    local IDX
    local -a A B
    IFS=. read -r -a A <<< "$1"
    IFS=. read -r -a B <<< "$2"
    # Compare over the longer of the two, otherwise 9.0 would wrongly be
    # reported as >= 9.0.1.
    local -i N=${#A[@]}
    if (( ${#B[@]} > N )); then N=${#B[@]}; fi
    for ((IDX = 0; IDX < N; IDX++)); do
        # ${A[$IDX]:-0} — an unset element is an unbound variable under `set -u`.
        if (( ${A[$IDX]:-0} > ${B[$IDX]:-0} )); then return 0; fi
        if (( ${A[$IDX]:-0} < ${B[$IDX]:-0} )); then return 1; fi
    done
    return 0
}

# Query ffmpeg.org's release listing for the newest FFmpeg release and
# reduce it to the release-branch version that BtbN bakes into its image
# names and upstream uses for the `release/x.y` git branch: 9.0.2 -> 9.0.
detect_latest_ffver() {
    local HTML V VER=""
    local -a VERSIONS=()

    HTML="$(curl -fsSL --max-time 30 https://ffmpeg.org/releases/ 2>/dev/null \
        || wget -qO- --timeout=30 https://ffmpeg.org/releases/)" || return 1

    while IFS= read -r V; do
        [[ -n "$V" ]] && VERSIONS+=("$V")
    done < <(printf '%s\n' "$HTML" \
        | grep -oE 'ffmpeg-[0-9]+(\.[0-9]+){1,2}\.tar\.(xz|bz2)' \
        | grep -oE '[0-9]+(\.[0-9]+){1,2}' \
        | sort -u)

    (( ${#VERSIONS[@]} == 0 )) && return 1
    VER="${VERSIONS[0]}"
    for V in "${VERSIONS[@]:1}"; do
        if ffver_ge "$V" "$VER"; then VER="$V"; fi
    done

    # 9.0.2 -> 9.0 ; 10.0 -> 10.0 (strip any patch number).
    printf '%s\n' "${VER%.*}"
}

# The fast lane can only build branches BtbN already publishes (the version
# is baked into the published image NAME, so there's no way to build an
# unreleased branch). Verify both target bases exist before burning hours.
check_base_images() {
    local T FOUND=1
    for T in linux64 win64; do
        if docker buildx imagetools inspect \
            "${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${T}-gpl-shared-${FFVER}:latest" \
            >/dev/null 2>&1; then
            echo ">>> base image available: ${T}-gpl-shared-${FFVER}:latest"
        else
            echo "    WARNING: ${T}-gpl-shared-${FFVER}:latest not on the registry"
            echo "    (BtbN may not have published that branch yet, or you're offline)."
            FOUND=0
        fi
    done
    if (( ! FOUND )); then
        echo "    The fast lane can only build FFmpeg branches BtbN already publishes."
        echo "    Wait for BtbN's CI, or pin a published branch: FAST_FFVER=9.0 ./fast.sh"
        exit 1
    fi
}

# Pull both gpl-shared base images once. Skipped silently if already present.
# These are the bulk of the speedup — all 120 deps live in these layers.
# BtbN's naming is `<target>-<variant>-<ffver>:latest` (version in the NAME,
# not the tag — every variant shares the `:latest` tag), per
# .github/workflows/build.yml:264,289.
pull_gpl_bases() {
    local REF
    for REF in \
        "${PUBLIC_REGISTRY}/${PUBLIC_REPO}/linux64-gpl-shared-${FFVER}:latest" \
        "${PUBLIC_REGISTRY}/${PUBLIC_REPO}/win64-gpl-shared-${FFVER}:latest"; do
        echo ">>> pulling $REF"
        if ! docker pull "$REF"; then
            echo "    WARNING: failed to pull $REF."
            echo "    If you are behind an auth proxy, run 'docker login ${PUBLIC_REGISTRY}' and retry."
        fi
    done
}

# Clone fdk-aac once — it's the only nonfree-specific dep. The source is
# mounted into the Docker build (via --mount) so it's available for compilation.
prepare_fdk_aac_source() {
    local SRC_DIR="${PWD}/.cache/fdk-aac-src"
    # Extract the commit from the source script (the value is double-quoted in the file)
    local COMMIT
    if ! COMMIT="$(grep '^SCRIPT_COMMIT=' scripts.d/50-fdk-aac.sh | cut -d'=' -f2 | tr -d '\n"')"; then
        echo "error: could not read SCRIPT_COMMIT from scripts.d/50-fdk-aac.sh"
        return 1
    fi
    if [[ -d "${SRC_DIR}/.git" ]]; then
        echo ">>> fdk-aac source already cloned (re-pinning to ${COMMIT})"
    else
        echo ">>> cloning fdk-aac source (commit ${COMMIT}) to .cache/fdk-aac-src"
        mkdir -p "${SRC_DIR}"
        git clone --filter=blob:none https://github.com/mstorsjo/fdk-aac.git "${SRC_DIR}"
    fi
    git -C "${SRC_DIR}" checkout "${COMMIT}"
}

check_disk() {
    local NEED_KB=20000000  # ~20 GB
    local AVAIL_KB
    # `|| true` — df fails if .cache does not exist yet, and with pipefail
    # that would abort the script under `set -e`.
    AVAIL_KB="$(df -Pk "${PWD}/.cache" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    if [[ -z "$AVAIL_KB" ]]; then return 0; fi
    if (( AVAIL_KB < NEED_KB )); then
        echo ">>> WARNING: only ${AVAIL_KB} KB free in $(dirname "${PWD}/.cache")"
        echo "    (recommended: >= $((NEED_KB/1000000)) GB). Continuing anyway."
    fi
}

# Build the FF_CONFIGURE flags for a given nonfree variant. Starts from the
# gpl-shared defaults used by BtbN's published image (so we match the
# dependency set that's already installed in the base), then adds --enable-
# nonfree and --enable-libfdk-aac.
build_ff_configure() {
    local TARGET="$1" VARIANT="$2"
    local CFG

    # Common gpl-shared flags — must match what's in BtbN's published
    # linux64-gpl-shared-${FFVER} / win64-gpl-shared-${FFVER} image (i.e.
    # the resolved release branch) so the deps it already has satisfy
    # ./configure.
    CFG="--enable-gpl --enable-version3 --disable-debug --disable-w32threads --enable-pthreads"
    CFG+=" --enable-iconv --enable-zlib --enable-libxml2 --enable-libvmaf"
    CFG+=" --enable-fontconfig --enable-libharfbuzz --enable-libfreetype --enable-libfribidi"
    CFG+=" --enable-vulkan --enable-libvorbis --disable-libxcb --disable-xlib"
    CFG+=" --disable-libpulse --enable-gmp --enable-lzma --enable-liblcevc-dec"
    CFG+=" --enable-opencl --enable-amf --enable-libaom --enable-libaribb24"
    CFG+=" --enable-avisynth --enable-chromaprint --enable-libdav1d --enable-libdavs2"
    CFG+=" --enable-libdvdread --enable-libdvdnav --enable-ffnvcodec --enable-cuda-llvm"
    CFG+=" --enable-frei0r --enable-libgme --enable-libkvazaar --enable-libaribcaption"
    CFG+=" --enable-libass --enable-libbluray --enable-libjxl --enable-libmp3lame"
    CFG+=" --enable-libopus --enable-libplacebo --enable-librist --enable-libssh"
    CFG+=" --enable-libtheora --enable-libvpx --enable-libwebp --enable-libzmq"
    CFG+=" --enable-lv2 --enable-libvpl --enable-openal --enable-liboapv"
    CFG+=" --enable-libopencore-amrnb --enable-libopencore-amrwb --enable-libopenh264"
    CFG+=" --enable-libopenjpeg --enable-libopenmpt --enable-librav1e"
    CFG+=" --enable-librubberband --enable-sdl2 --enable-libsnappy"
    CFG+=" --enable-libsoxr --enable-libsrt --enable-libsvtav1 --enable-libtwolame"
    CFG+=" --enable-libuavs3d --disable-libdrm --enable-libvidstab"
    CFG+=" --enable-libvvenc --disable-whisper --enable-libx264 --enable-libx265"
    CFG+=" --enable-libxavs2 --enable-libxvid --enable-libzimg --enable-libzvbi"

    # Nonfree additions.
    CFG+=" --enable-nonfree --enable-libfdk-aac"

    # Static vs shared. For the "nonfree" variant we want static ffmpeg,
    # matching gpl (the gpl-shared image's deps support both).
    if [[ "$VARIANT" == *-shared ]]; then
        CFG+=" --enable-shared --disable-static"
    else
        CFG+=" --disable-shared --enable-static"
    fi

    # Target-specific TLS backend / VA-API. schannel is Windows-only
    # (scripts.d/50-schannel.sh) and vaapi + openssl are the Linux answers
    # (scripts.d/50-vaapi, scripts.d/25-openssl.sh). BtbN's gpl-shared image
    # ships openssl+vaapi on linux64 and schannel on win64, so enable each
    # only where its dep actually exists.
    if [[ "$TARGET" == linux* ]]; then
        CFG+=" --enable-openssl --enable-vaapi"
    else
        CFG+=" --enable-schannel"
    fi

    printf '%s\n' "$CFG"
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
    local TARGET="$1" VARIANT="$2"
    local KEY="${TARGET} ${VARIANT}"
    local BASE_REF="${GPL_BASE[$KEY]}"
    local OVERLAY_TAG="${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${TARGET}-${VARIANT}:${FFVER}"
    local DOCKERFILE=".cache/Dockerfile.nonfree.${TARGET}-${VARIANT}"
    local FF_CFG

    FF_CFG="$(build_ff_configure "$TARGET" "$VARIANT")"

    mkdir -p .cache
    echo
    echo "============================================================"
    echo "  Building overlay: ${TARGET} ${VARIANT} (FFmpeg ${FFVER})"
    echo "  Base: ${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${BASE_REF}"
    echo "  Tag:  ${OVERLAY_TAG}"
    echo "============================================================"

    # Extract the fdk-aac commit from the source script without hardcoding it
    local FDK_AAC_COMMIT
    if ! FDK_AAC_COMMIT="$(grep '^SCRIPT_COMMIT=' scripts.d/50-fdk-aac.sh | cut -d'=' -f2 | tr -d '\n"')"; then
        echo "error: could not read SCRIPT_COMMIT from scripts.d/50-fdk-aac.sh"
        return 1
    fi

    cat >"$DOCKERFILE" <<EOF
# Auto-generated by fast.sh — do not edit.
# Starts FROM the published gpl-shared image (all 120 deps already at
# /opt/ffbuild/) and adds fdk-aac, the only nonfree-specific dep.
FROM ${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${BASE_REF}

ARG FDK_AAC_COMMIT
RUN --mount=src=.cache/fdk-aac-src,dst=/src,rw \
    set -eux; \
    if [[ ! -d /src/.git ]]; then \
        git clone --filter=blob:none https://github.com/mstorsjo/fdk-aac.git /src; \
        git -C /src checkout \"\$FDK_AAC_COMMIT\"; \
    fi; \
    cd /src; \
    ./autogen.sh; \
    ./configure --prefix="\$FFBUILD_PREFIX" --disable-shared --enable-static --with-pic --disable-example \
        --host="\$FFBUILD_TOOLCHAIN"; \
    make -j\$(nproc); \
    make install; \
    true

# Bake the FFmpeg configure flags. Static vs shared is already encoded in
# FF_CONFIGURE. FF_CFLAGS/FF_LDFLAGS/FF_LIBS match what upstream uses in
# the generated Dockerfile for the equivalent nonfree variant.
ENV FF_CONFIGURE="${FF_CFG}" \\
    FF_CFLAGS="-DLIBTWOLAME_STATIC" \\
    FF_CXXFLAGS="" \\
    FF_LDFLAGS="-pthread" \\
    FF_LDEXEFLAGS="" \\
    FF_LIBS="-lgomp" \\
    GIT_BRANCH="release/${FFVER}"
EOF

    docker buildx --builder "$BUILDER_NAME" build \
        --build-arg FDK_AAC_COMMIT="$FDK_AAC_COMMIT" \
        --cache-from "type=registry,ref=${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${BASE_REF}" \
        --cache-to   "type=local,mode=max,dest=.cache/${OVERLAY_TAG//\//_}" \
        --load --tag "$OVERLAY_TAG" \
        --file "$DOCKERFILE" \
        .
}

# Drive the configure+make+install inside the overlay image. Mirrors what
# build.sh does for the upstream-generated Dockerfile, but skips the host-
# side vars.sh/variants dance because FF_CONFIGURE is already baked in.
run_ffmpeg_build() {
    local TARGET="$1" VARIANT="$2"
    local OVERLAY_TAG="${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${TARGET}-${VARIANT}:${FFVER}"
    local BUILD_SCRIPT=".cache/build-ffmpeg.${TARGET}-${VARIANT}.sh"

    echo
    echo ">>> building ffmpeg inside $OVERLAY_TAG"

    # Pick the right FFmpeg branch matching the addin.
    local GIT_BRANCH="release/${FFVER}"

    cat >"$BUILD_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euxo pipefail
cd /ffbuild
rm -rf ffmpeg prefix

git clone --filter=blob:none --branch='${GIT_BRANCH}' https://github.com/FFmpeg/FFmpeg.git ffmpeg
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
    local -a UIDARGS=()
    if ! docker info -f '{{println .SecurityOptions}}' | grep rootless >/dev/null 2>&1; then
        UIDARGS=( -u "$(id -u):$(id -g)" )
    fi
    local -a TTY_ARGS=()
    if [[ -t 1 ]]; then
        TTY_ARGS=( -t )
    fi

    mkdir -p ".cache/ffbuild-output/${TARGET}-${VARIANT}"
    docker run --rm -i "${TTY_ARGS[@]}" "${UIDARGS[@]}" \
        -v "${PWD}/.cache/ffbuild-output/${TARGET}-${VARIANT}":/ffbuild \
        -v "${PWD}/${BUILD_SCRIPT}":/build.sh \
        "$OVERLAY_TAG" \
        bash /build.sh
}

# Package the freshly built prefix into a compressed archive in artifacts/,
# mirroring build.sh's naming: ffmpeg-<version>-<target>-<variant>.zip|.tar.xz
# where <version> comes from FFmpeg's own ffbuild/version.sh (e.g.
# n9.0.2-3-g...). The archive is produced inside the overlay image via a
# docker run so GNU tar/xz and zip are guaranteed regardless of the host.
# The directory inside the archive is shortened to ffmpeg-<base-version>.
package_output() {
    local TARGET="$1" VARIANT="$2" KEY="${1}-${2}"
    local OVERLAY_TAG="${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${KEY}:${FFVER}"
    local BUILD_ROOT=".cache/ffbuild-output/${KEY}"
    local PKG_ROOT=".cache/pkgroot/${KEY}"

    local VERSION
    VERSION="$(cd "${BUILD_ROOT}/ffmpeg" && ./ffbuild/version.sh .)" || return 1
    # The archive keeps the full name (version + target + variant), but the
    # directory inside it is shortened to just the version (ffmpeg-n9.0.2) so
    # that unpacking doesn't create an unwieldy directory.
    local BUILD_NAME="ffmpeg-${VERSION}-${KEY}"
    local PKG_DIR="ffmpeg-${VERSION%%-*}"

    echo
    echo ">>> packaging ${BUILD_NAME} (dir: ${PKG_DIR})"

    rm -rf "$PKG_ROOT"
    mkdir -p "$PKG_ROOT/$PKG_DIR" artifacts
    cp -a "${BUILD_ROOT}/prefix/." "$PKG_ROOT/$PKG_DIR/"

    # The .pc files were generated with --prefix=/ffbuild/prefix, a path that
    # only exists inside the build container. Point them at the package's own
    # prefix instead, so the package works wherever it is unpacked. The first
    # three expressions are the ones upstream uses in
    # variants/linux-install-shared.sh.
    # The fourth one is for the static builds: there FFmpeg inlines the
    # private dependency list into the Libs: line rather than keeping it in a
    # separate Libs.private: line, so it has to be cut off at the first
    # absolute path — those point into the build container and name
    # libraries that are not part of the package.
    # sed -i is avoided here because it is spelled differently on GNU and BSD.
    local PC
    for PC in "$PKG_ROOT/$PKG_DIR"/lib/pkgconfig/*.pc; do
        [[ -f "$PC" ]] || continue
        # shellcheck disable=SC2016  # ${pcfiledir}/${prefix} are expanded by pkg-config, not by the shell
        sed -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' \
            -e 's|/ffbuild/prefix|${prefix}|' \
            -e '/Libs.private:/d' \
            -e 's|^\(Libs:\([^ /]* \)*\)[^ /]*[/].*$|\1|' \
            "$PC" >"$PC.new"
        mv -f "$PC.new" "$PC"
    done

    # Linux packages ship an installer so the build can be dropped into
    # /usr/local without unpacking the tree by hand.
    if [[ "$TARGET" == linux* ]]; then
        install -m 0755 fast-install.sh "$PKG_ROOT/$PKG_DIR/install.sh"
    fi

    # UID mapping (skip under rootless docker).
    local -a UIDARGS=()
    if ! docker info -f '{{println .SecurityOptions}}' | grep rootless >/dev/null 2>&1; then
        UIDARGS=( -u "$(id -u):$(id -g)" )
    fi
    local -a TTY_ARGS=()
    if [[ -t 1 ]]; then
        TTY_ARGS=( -t )
    fi

    local FNAME
    if [[ "$TARGET" == win* ]]; then
        FNAME="${BUILD_NAME}.zip"
        docker run --rm -i "${TTY_ARGS[@]}" "${UIDARGS[@]}" \
            -v "${PWD}/artifacts":/out \
            -v "${PWD}/${PKG_ROOT}/${PKG_DIR}:/${PKG_DIR}" \
            -w / "$OVERLAY_TAG" zip -9 -r "/out/${FNAME}" "$PKG_DIR"
    else
        FNAME="${BUILD_NAME}.tar.xz"
        docker run --rm -i "${TTY_ARGS[@]}" "${UIDARGS[@]}" \
            -v "${PWD}/artifacts":/out \
            -v "${PWD}/${PKG_ROOT}/${PKG_DIR}:/${PKG_DIR}" \
            -w / "$OVERLAY_TAG" tar -I "xz -T0" -cf "/out/${FNAME}" "$PKG_DIR"
    fi

    rm -rf "$PKG_ROOT"
    echo ">>> artifact: ${PWD}/artifacts/${FNAME}"
}

cleanup_caches() {
    if [[ "${FAST_KEEP_CACHES:-1}" == "1" ]]; then
        echo ">>> leaving .cache/ and the builder in place (FAST_KEEP_CACHES=1)"
        return 0
    fi
    echo ">>> removing .cache/ and the buildkit builder"
    rm -rf "${PWD}/.cache" || true
    docker buildx rm -f "$BUILDER_NAME" 2>/dev/null || true
}

main() {
    local ONLY_TARGET="${1:-}"
    local ONLY_VARIANT="${2:-}"

    mkdir -p .cache

    # Resolve which FFmpeg release branch to build. Default: the newest
    # release on ffmpeg.org reduced to its release branch (9.0.2 -> 9.0),
    # which is both BtbN's image-name version and upstream's release/x.y
    # git branch. Pin it explicitly with FAST_FFVER to skip detection.
    if [[ -n "${FAST_FFVER:-}" ]]; then
        FFVER="$FAST_FFVER"
        echo ">>> pinned FFmpeg release branch: ${FFVER} (FAST_FFVER)"
    elif FFVER="$(detect_latest_ffver)"; then
        echo ">>> latest FFmpeg release on ffmpeg.org: ${FFVER}"
    else
        echo ">>> WARNING: couldn't reach ffmpeg.org — using fallback ${FFVER} (set FAST_FFVER to pin)"
    fi

    GPL_BASE=(
        ["linux64 nonfree"]="linux64-gpl-shared-${FFVER}:latest"
        ["linux64 nonfree-shared"]="linux64-gpl-shared-${FFVER}:latest"
        ["win64 nonfree"]="win64-gpl-shared-${FFVER}:latest"
        ["win64 nonfree-shared"]="win64-gpl-shared-${FFVER}:latest"
    )

    check_disk
    check_base_images
    create_builder
    pull_gpl_bases
    prepare_fdk_aac_source

    local -i I
    for ((I = 0; I < ${#ALL_TARGETS[@]}; I += 2)); do
        local TARGET="${ALL_TARGETS[$I]}"
        local VARIANT="${ALL_TARGETS[$((I + 1))]}"

        if [[ -n "$ONLY_TARGET" && "$TARGET" != "$ONLY_TARGET" ]]; then
            continue
        fi
        if [[ -n "$ONLY_VARIANT" && "$VARIANT" != "$ONLY_VARIANT" ]]; then
            continue
        fi

        build_overlay "$TARGET" "$VARIANT"
        run_ffmpeg_build "$TARGET" "$VARIANT"
        package_output "$TARGET" "$VARIANT"
    done

    cleanup_caches

    echo
    echo ">>> all requested builds complete"
    echo ">>> built images:"
    docker images --filter "reference=${PUBLIC_REGISTRY}/${PUBLIC_REPO}/*nonfree*${FFVER}*" \
        --format "    {{.Repository}}:{{.Tag}}  ({{.Size}})" || true
    echo
    echo ">>> ffmpeg binaries:"
    find .cache/ffbuild-output -type f \( -name ffmpeg -o -name ffmpeg.exe \) 2>/dev/null \
        | sed 's/^/    /' || true
    echo
    echo ">>> artifacts:"
    # shellcheck disable=SC2012  # human-readable summary; ls -lh sizes are the point
    ls -lh artifacts/*.{zip,tar.xz} 2>/dev/null | sed 's/^/    /' || true
}

main "$@"
