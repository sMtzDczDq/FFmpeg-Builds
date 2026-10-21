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
IFS=$'\n\t'
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
    local n
    n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || printf '%s\n' 2)"
    # Cap at 4 by default: each dep compile is fs-heavy and on virtualised
    # disks (qcow2/VMDK) more parallelism just thrashes the disk. Override
    # via FAST_PARALLELISM=N.
    if (( n > 4 )); then n=4; fi
    printf '%s\n' "$n"
}

create_builder() {
    if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
        printf '%s\n' ">>> buildx builder '$BUILDER_NAME' already exists, reusing"
        return 0
    fi

    local parallelism="${FAST_PARALLELISM:-$(detect_parallelism)}"
    printf '%s\n' ">>> creating buildx builder '$BUILDER_NAME' (parallelism=$parallelism)"

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
    if [[ "${FAST_NO_HOST_NET:-0}" != "1" ]]; then
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

# Numeric compare for dotted version strings (x.y.z) without relying on
# `sort -V` (BSD sort on macOS lacks it). Returns 0 if $1 >= $2.
ffver_ge() {
    local i
    local -a a b
    IFS=. read -r -a a <<< "$1"
    IFS=. read -r -a b <<< "$2"
    # Compare over the longer of the two, otherwise 9.0 would wrongly be
    # reported as >= 9.0.1.
    local -i n=${#a[@]}
    if (( ${#b[@]} > n )); then n=${#b[@]}; fi
    for ((i = 0; i < n; i++)); do
        # ${a[$i]:-0} — an unset element is an unbound variable under `set -u`.
        if (( ${a[$i]:-0} > ${b[$i]:-0} )); then return 0; fi
        if (( ${a[$i]:-0} < ${b[$i]:-0} )); then return 1; fi
    done
    return 0
}

# Query ffmpeg.org's release listing for the newest FFmpeg release and
# reduce it to the release-branch version that BtbN bakes into its image
# names and upstream uses for the `release/x.y` git branch: 9.0.2 -> 9.0.
detect_latest_ffver() {
    local html v ver=""
    local -a versions=()

    html="$(curl -fsSL --max-time 30 https://ffmpeg.org/releases/ 2>/dev/null \
        || wget -qO- --timeout=30 https://ffmpeg.org/releases/)" || return 1

    while IFS= read -r v; do
        [[ -n "$v" ]] && versions+=("$v")
    done < <(printf '%s\n' "$html" \
        | grep -oE 'ffmpeg-[0-9]+(\.[0-9]+){1,2}\.tar\.(xz|bz2)' \
        | grep -oE '[0-9]+(\.[0-9]+){1,2}' \
        | sort -u)

    (( ${#versions[@]} == 0 )) && return 1
    ver="${versions[0]}"
    for v in "${versions[@]:1}"; do
        if ffver_ge "$v" "$ver"; then ver="$v"; fi
    done

    # 9.0.2 -> 9.0 ; 10.0 -> 10.0 (strip any patch number).
    printf '%s\n' "${ver%.*}"
}

# The fast lane can only build branches BtbN already publishes (the version
# is baked into the published image NAME, so there's no way to build an
# unreleased branch). Verify both target bases exist before burning hours.
check_base_images() {
    local t found=1
    for t in linux64 win64; do
        if docker buildx imagetools inspect \
            "${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${t}-gpl-shared-${FFVER}:latest" \
            >/dev/null 2>&1; then
            printf '%s\n' ">>> base image available: ${t}-gpl-shared-${FFVER}:latest"
        else
            printf '%s\n' "    WARNING: ${t}-gpl-shared-${FFVER}:latest not on the registry"
            printf '%s\n' "    (BtbN may not have published that branch yet, or you're offline)."
            found=0
        fi
    done
    if (( ! found )); then
        printf '%s\n' "    The fast lane can only build FFmpeg branches BtbN already publishes."
        printf '%s\n' "    Wait for BtbN's CI, or pin a published branch: FAST_FFVER=9.0 ./fast.sh"
        exit 1
    fi
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
        printf '%s\n' ">>> pulling $ref"
        if ! docker pull "$ref"; then
            printf '%s\n' "    WARNING: failed to pull $ref."
            printf '%s\n' "    If you are behind an auth proxy, run 'docker login ${PUBLIC_REGISTRY}' and retry."
        fi
    done
}

# Clone fdk-aac once — it's the only nonfree-specific dep. The source is
# mounted into the Docker build (via --mount) so it's available for compilation.
prepare_fdk_aac_source() {
    local src_dir="${PWD}/.cache/fdk-aac-src"
    # Extract the commit from the source script (the value is double-quoted in the file)
    local commit
    commit="$(grep '^SCRIPT_COMMIT=' scripts.d/50-fdk-aac.sh | cut -d'=' -f2 | tr -d '\n"')"
    if [[ -d "${src_dir}/.git" ]]; then
        printf '%s\n' ">>> fdk-aac source already cloned (re-pinning to ${commit})"
    else
        printf '%s\n' ">>> cloning fdk-aac source (commit ${commit}) to .cache/fdk-aac-src"
        mkdir -p "${src_dir}"
        git clone --filter=blob:none https://github.com/mstorsjo/fdk-aac.git "${src_dir}"
    fi
    git -C "${src_dir}" checkout "${commit}"
}

check_disk() {
    local need_kb=20000000  # ~20 GB
    local avail_kb
    # `|| true` — df fails if .cache does not exist yet, and with pipefail
    # that would abort the script under `set -e`.
    avail_kb="$(df -Pk "${PWD}/.cache" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
    if [[ -z "$avail_kb" ]]; then return 0; fi
    if (( avail_kb < need_kb )); then
        printf '%s\n' ">>> WARNING: only ${avail_kb} KB free in $(dirname "${PWD}/.cache")"
        printf '%s\n' "    (recommended: >= $((need_kb/1000000)) GB). Continuing anyway."
    fi
}

# Build the FF_CONFIGURE flags for a given nonfree variant. Starts from the
# gpl-shared defaults used by BtbN's published image (so we match the
# dependency set that's already installed in the base), then adds --enable-
# nonfree and --enable-libfdk-aac.
build_ff_configure() {
    local target="$1" variant="$2"
    local cfg

    # Common gpl-shared flags — must match what's in BtbN's published
    # linux64-gpl-shared-${FFVER} / win64-gpl-shared-${FFVER} image (i.e.
    # the resolved release branch) so the deps it already has satisfy
    # ./configure.
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
    cfg+=" --enable-librubberband --enable-sdl2 --enable-libsnappy"
    cfg+=" --enable-libsoxr --enable-libsrt --enable-libsvtav1 --enable-libtwolame"
    cfg+=" --enable-libuavs3d --disable-libdrm --enable-libvidstab"
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

    # Target-specific TLS backend / VA-API. schannel is Windows-only
    # (scripts.d/50-schannel.sh) and vaapi + openssl are the Linux answers
    # (scripts.d/50-vaapi, scripts.d/25-openssl.sh). BtbN's gpl-shared image
    # ships openssl+vaapi on linux64 and schannel on win64, so enable each
    # only where its dep actually exists.
    if [[ "$target" == linux* ]]; then
        cfg+=" --enable-openssl --enable-vaapi"
    else
        cfg+=" --enable-schannel"
    fi

    printf '%s\n' "$cfg"
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
    local target="$1" variant="$2"
    local key="${target} ${variant}"
    local base_ref="${GPL_BASE[$key]}"
    local overlay_tag="${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${target}-${variant}:${FFVER}"
    local dockerfile=".cache/Dockerfile.nonfree.${target}-${variant}"
    local ff_cfg

    ff_cfg="$(build_ff_configure "$target" "$variant")"

    mkdir -p .cache
    printf '\n'
    printf '%s\n' "============================================================"
    printf '%s\n' "  Building overlay: ${target} ${variant} (FFmpeg ${FFVER})"
    printf '%s\n' "  Base: ${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${base_ref}"
    printf '%s\n' "  Tag:  ${overlay_tag}"
    printf '%s\n' "============================================================"

    # Extract the fdk-aac commit from the source script without hardcoding it
    local fdk_aac_commit
    if ! fdk_aac_commit="$(grep '^SCRIPT_COMMIT=' scripts.d/50-fdk-aac.sh | cut -d'=' -f2 | tr -d '\n"')"; then
        printf 'error: could not read SCRIPT_COMMIT from scripts.d/50-fdk-aac.sh\n' >&2
        return 1
    fi

    cat >"$dockerfile" <<EOF
# Auto-generated by fast.sh — do not edit.
# Starts FROM the published gpl-shared image (all 120 deps already at
# /opt/ffbuild/) and adds fdk-aac, the only nonfree-specific dep.
FROM ${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${base_ref}

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
ENV FF_CONFIGURE="${ff_cfg}" \\
    FF_CFLAGS="-DLIBTWOLAME_STATIC" \\
    FF_CXXFLAGS="" \\
    FF_LDFLAGS="-pthread" \\
    FF_LDEXEFLAGS="" \\
    FF_LIBS="-lgomp" \\
    GIT_BRANCH="release/${FFVER}"
EOF

    docker buildx --builder "$BUILDER_NAME" build \
        --build-arg FDK_AAC_COMMIT="$fdk_aac_commit" \
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
    local target="$1" variant="$2"
    local overlay_tag="${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${target}-${variant}:${FFVER}"
    local build_script=".cache/build-ffmpeg.${target}-${variant}.sh"

    printf '\n'
    printf '%s\n' ">>> building ffmpeg inside $overlay_tag"

    # Pick the right FFmpeg branch matching the addin.
    local git_branch="release/${FFVER}"

    cat >"$build_script" <<EOF
#!/usr/bin/env bash
set -euxo pipefail
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
    local -a tty_args=()
    if [[ -t 1 ]]; then
        tty_args=( -t )
    fi

    mkdir -p ".cache/ffbuild-output/${target}-${variant}"
    docker run --rm -i "${tty_args[@]}" "${uidargs[@]}" \
        -v "${PWD}/.cache/ffbuild-output/${target}-${variant}":/ffbuild \
        -v "${PWD}/${build_script}":/build.sh \
        "$overlay_tag" \
        bash /build.sh
}

# Package the freshly built prefix into a compressed archive in artifacts/,
# mirroring build.sh's naming: ffmpeg-<version>-<target>-<variant>.zip|.tar.xz
# where <version> comes from FFmpeg's own ffbuild/version.sh (e.g.
# n9.0.2-3-g...). The archive is produced inside the overlay image via a
# docker run so GNU tar/xz and zip are guaranteed regardless of the host.
# The directory inside the archive is shortened to ffmpeg-<base-version>.
package_output() {
    local target="$1" variant="$2" key="${1}-${2}"
    local overlay_tag="${PUBLIC_REGISTRY}/${PUBLIC_REPO}/${key}:${FFVER}"
    local build_root=".cache/ffbuild-output/${key}"
    local pkg_root=".cache/pkgroot/${key}"

    local version
    version="$(cd "${build_root}/ffmpeg" && ./ffbuild/version.sh .)" || return 1
    # The archive keeps the full name (version + target + variant), but the
    # directory inside it is shortened to just the version (ffmpeg-n9.0.2) so
    # that unpacking doesn't create an unwieldy directory.
    local build_name="ffmpeg-${version}-${key}"
    local pkg_dir="ffmpeg-${version%%-*}"

    printf '\n'
    printf '%s\n' ">>> packaging ${build_name} (dir: ${pkg_dir})"

    rm -rf "$pkg_root"
    mkdir -p "$pkg_root/$pkg_dir" artifacts
    cp -a "${build_root}/prefix/." "$pkg_root/$pkg_dir/"

    # Linux packages ship an installer so the build can be dropped into
    # /usr/local without unpacking the tree by hand.
    if [[ "$target" == linux* ]]; then
        install -m 0755 fast-install.sh "$pkg_root/$pkg_dir/install.sh"
    fi

    # UID mapping (skip under rootless docker).
    local -a uidargs=()
    if ! docker info -f '{{println .SecurityOptions}}' | grep rootless >/dev/null 2>&1; then
        uidargs=( -u "$(id -u):$(id -g)" )
    fi
    local -a tty_args=()
    if [[ -t 1 ]]; then
        tty_args=( -t )
    fi

    local fname
    if [[ "$target" == win* ]]; then
        fname="${build_name}.zip"
        docker run --rm -i "${tty_args[@]}" "${uidargs[@]}" \
            -v "${PWD}/artifacts":/out \
            -v "${PWD}/${pkg_root}/${pkg_dir}:/${pkg_dir}" \
            -w / "$overlay_tag" zip -9 -r "/out/${fname}" "$pkg_dir"
    else
        fname="${build_name}.tar.xz"
        docker run --rm -i "${tty_args[@]}" "${uidargs[@]}" \
            -v "${PWD}/artifacts":/out \
            -v "${PWD}/${pkg_root}/${pkg_dir}:/${pkg_dir}" \
            -w / "$overlay_tag" tar -I "xz -T0" -cf "/out/${fname}" "$pkg_dir"
    fi

    rm -rf "$pkg_root"
    printf '%s\n' ">>> artifact: ${PWD}/artifacts/${fname}"
}

cleanup_caches() {
    if [[ "${FAST_KEEP_CACHES:-1}" == "1" ]]; then
        printf '%s\n' ">>> leaving .cache/ and the builder in place (FAST_KEEP_CACHES=1)"
        return 0
    fi
    printf '%s\n' ">>> removing .cache/ and the buildkit builder"
    rm -rf "${PWD}/.cache" || true
    docker buildx rm -f "$BUILDER_NAME" 2>/dev/null || true
}

main() {
    local only_target="${1:-}"
    local only_variant="${2:-}"

    mkdir -p .cache

    # Resolve which FFmpeg release branch to build. Default: the newest
    # release on ffmpeg.org reduced to its release branch (9.0.2 -> 9.0),
    # which is both BtbN's image-name version and upstream's release/x.y
    # git branch. Pin it explicitly with FAST_FFVER to skip detection.
    if [[ -n "${FAST_FFVER:-}" ]]; then
        FFVER="$FAST_FFVER"
        printf '%s\n' ">>> pinned FFmpeg release branch: ${FFVER} (FAST_FFVER)"
    elif FFVER="$(detect_latest_ffver)"; then
        printf '%s\n' ">>> latest FFmpeg release on ffmpeg.org: ${FFVER}"
    else
        printf '%s\n' ">>> WARNING: couldn't reach ffmpeg.org — using fallback ${FFVER} (set FAST_FFVER to pin)" >&2
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

    local -i i
    for ((i = 0; i < ${#ALL_TARGETS[@]}; i += 2)); do
        local target="${ALL_TARGETS[$i]}"
        local variant="${ALL_TARGETS[$((i + 1))]}"

        if [[ -n "$only_target" && "$target" != "$only_target" ]]; then
            continue
        fi
        if [[ -n "$only_variant" && "$variant" != "$only_variant" ]]; then
            continue
        fi

        build_overlay "$target" "$variant"
        run_ffmpeg_build "$target" "$variant"
        package_output "$target" "$variant"
    done

    cleanup_caches

    printf '\n'
    printf '%s\n' ">>> all requested builds complete"
    printf '%s\n' ">>> built images:"
    docker images --filter "reference=${PUBLIC_REGISTRY}/${PUBLIC_REPO}/*nonfree*${FFVER}*" \
        --format "    {{.Repository}}:{{.Tag}}  ({{.Size}})" || true
    printf '\n'
    printf '%s\n' ">>> ffmpeg binaries:"
    find .cache/ffbuild-output -type f \( -name ffmpeg -o -name ffmpeg.exe \) 2>/dev/null \
        | sed 's/^/    /' || true
    printf '\n'
    printf '%s\n' ">>> artifacts:"
    # shellcheck disable=SC2012  # human-readable summary; ls -lh sizes are the point
    ls -lh artifacts/*.{zip,tar.xz} 2>/dev/null | sed 's/^/    /' || true
}

main "$@"
