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
#   bin/*     -> $PREFIX/bin
#   lib/*     -> $PREFIX/lib
#   include/* -> $PREFIX/include
#   share/*   -> $PREFIX/share
#
# Both package flavours are handled by the same script. A shared build ships
# libav*.so plus the .so -> .so.N -> .so.N.N symlink chain, and the linker
# cache is refreshed afterwards. A static build ships libav*.a instead and has
# no shared libraries to register.
#
set -e

PREFIX="${PREFIX:-/usr/local}"
SRC="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -d "$SRC"/bin ]]; then
    echo "No FFmpeg build found in $SRC"
    exit 1
fi

if ! mkdir -p "$PREFIX" || [[ ! -w "$PREFIX" ]]; then
    echo "Cannot write to $PREFIX - re-run with sudo, or set PREFIX to a directory you can write to."
    exit 1
fi

echo "Installing FFmpeg into $PREFIX"

# Copy with -a so the shared library symlink chain survives. 'install' would
# dereference it and store a second copy of the real library per name.
mkdir -p "$PREFIX"/bin
cp -a "$SRC"/bin/* "$PREFIX"/bin

mkdir -p "$PREFIX"/lib
cp -a "$SRC"/lib/* "$PREFIX"/lib

mkdir -p "$PREFIX"/include
cp -a "$SRC"/include/* "$PREFIX"/include

mkdir -p "$PREFIX"/share
cp -a "$SRC"/share/* "$PREFIX"/share

# Refresh the dynamic linker cache. Only /usr and /usr/local are in the
# default search path, and only root can write the cache. A static build
# ships no shared libraries, so there is nothing to register.
shopt -s nullglob
SOFILES=( "$SRC"/lib/*.so* )
if [[ ${#SOFILES[@]} -gt 0 ]]; then
    if [[ "$PREFIX" == /usr || "$PREFIX" == /usr/local ]]; then
        if [[ $EUID -eq 0 ]] && command -v ldconfig >/dev/null 2>&1; then
            ldconfig
        else
            echo "Note: not running as root, skipping ldconfig."
        fi
    else
        echo "Note: $PREFIX is not a system prefix - add $PREFIX/lib to your linker search path."
    fi
fi

echo "Done. $PREFIX/bin may need to be added to your PATH."
