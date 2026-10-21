#!/usr/bin/env bash
#
# install.sh — copy an unpacked FFmpeg prefix into a destination prefix.
#
# Usage: install.sh INDIR OUTDIR
#
set -euo pipefail
IFS=$'\n\t'

if (( $# != 2 )); then
    printf 'Usage: install.sh INDIR OUTDIR\n'
    exit 1
fi

INDIR="$1"
OUTDIR="$2"

mkdir -p "${OUTDIR}/bin"
cp "${INDIR}"/bin/* "${OUTDIR}"/bin

mkdir -p "${OUTDIR}/lib"
cp -a "${INDIR}"/lib/*.so* "${OUTDIR}"/lib

mkdir -p "${OUTDIR}/lib/pkgconfig"
cp -a "${INDIR}"/lib/pkgconfig/*.pc "${OUTDIR}"/lib/pkgconfig

mkdir -p "${OUTDIR}/include"
cp -a "${INDIR}"/include/* "${OUTDIR}"/include

mkdir -p "${OUTDIR}/doc"
cp -a "${INDIR}"/doc/* "${OUTDIR}"/doc

mkdir -p "${OUTDIR}/man"
cp -a "${INDIR}"/man/* "${OUTDIR}"/man

# Refresh the dynamic linker cache. Only root can write /etc/ld.so.cache, and
# it is only useful when installing into a system library directory, so skip it
# otherwise instead of failing with a confusing permission error.
if (( EUID == 0 )); then
    ldconfig
else
    printf 'Note: not running as root, skipping ldconfig.\n'
    printf '      Add %s/lib to your linker search path if the libraries are not found.\n' "$OUTDIR"
fi
