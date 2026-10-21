#!/usr/bin/env bash
#
# Install this FFmpeg build into $PREFIX (default: /usr/local).
#
# This script is shipped inside the Linux packages produced by fast.sh, so a
# build can be dropped into the system without unpacking the tree by hand:
#
#   tar xf ffmpeg-n9.0.2-30-g20339a85af-linux64-nonfree-shared.tar.xz
#   cd ffmpeg-n9.0.2
#   sudo ./install.sh
#
# To install somewhere else:
#
#   PREFIX=/opt/ffmpeg ./install.sh
#
# What gets installed:
#
#   bin/*              -> $PREFIX/bin
#   lib/*              -> $PREFIX/lib
#   lib/pkgconfig/*.pc -> $PREFIX/lib/pkgconfig
#   include/*          -> $PREFIX/include
#   share/*            -> $PREFIX/share
#
# Both package flavours are handled by the same script. A shared build ships
# libav*.so plus the .so -> .so.N -> .so.N.N.N symlink chain, and the linker
# cache is refreshed afterwards. A static build ships libav*.a instead and has
# no shared libraries to register.
#
set -euo pipefail
IFS=$'\n\t'

PREFIX="${PREFIX:-/usr/local}"
SRC="$(cd "$(dirname "$0")" && pwd)"

say() { printf '  %s\n' "$*"; }

# Copy the contents of $SRC/<src> into $PREFIX/<dst>, preserving symlinks and
# permissions. Does nothing when the source directory is absent.
copy_tree() {
    local src="$SRC/$1" dst="$PREFIX/$2" f
    [[ -d "$src" ]] || return 0
    mkdir -p "$dst"
    for f in "$src"/*; do
        [[ -e "$f" ]] || continue
        cp -a "$f" "$dst/"
    done
}

if ! mkdir -p "$PREFIX" 2>/dev/null; then
    printf 'error: cannot create %s\n' "$PREFIX" >&2
    exit 1
fi
if [[ ! -w "$PREFIX" ]]; then
    printf 'error: %s is not writable - re-run with sudo, or set PREFIX to a\n' "$PREFIX" >&2
    printf '       directory you can write to.\n' >&2
    exit 1
fi

printf 'Installing FFmpeg into %s\n' "$PREFIX"

# Executables.
copy_tree bin bin
say "bin"

# Libraries. Shared builds ship .so files and their symlinks, static builds
# ship .a archives. Both are copied as-is: 'install' would dereference the
# symlinks and duplicate the real library once per name.
copy_tree lib lib
say "lib"

# pkg-config files. FFmpeg is configured with --prefix=/ffbuild/prefix inside
# the build container, so the .pc files point at a prefix that does not exist
# on the target system. Point them at the prefix we are installing into.
if [[ -d "$PREFIX/lib/pkgconfig" ]]; then
    for pc in "$PREFIX"/lib/pkgconfig/*.pc; do
        [[ -f "$pc" ]] || continue
        grep -q '^prefix=' "$pc" || continue
        awk -v prefix="$PREFIX" '
            /^prefix=/     { print "prefix=" prefix;         next }
            /^libdir=/     { print "libdir=" prefix "/lib";   next }
            /^includedir=/ { print "includedir=" prefix "/include"; next }
            { print }
        ' "$pc" > "$pc.new"
        mv -f "$pc.new" "$pc"
    done
    say "lib/pkgconfig"
fi

# Headers.
copy_tree include include
say "include"

# Documentation, man pages and presets.
copy_tree share share
say "share"

# Refresh the dynamic linker cache. Only /usr and /usr/local are in the
# default linker search path, and only root can write the cache.
HAS_SHARED=0
for f in "$PREFIX"/lib/*.so*; do
    if [[ -e "$f" ]]; then
        HAS_SHARED=1
        break
    fi
done

if (( HAS_SHARED == 1 )); then
    if [[ "$PREFIX" == /usr || "$PREFIX" == /usr/local ]]; then
        if (( EUID == 0 )) && command -v ldconfig >/dev/null 2>&1; then
            ldconfig || say "warning: ldconfig failed"
        else
            say "note: skipping ldconfig (it needs root)"
        fi
    else
        say "note: $PREFIX is not a system prefix - add $PREFIX/lib to the linker search path"
    fi
fi

printf 'Done. %s/bin may need to be added to your PATH.\n' "$PREFIX"
