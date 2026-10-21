#!/usr/bin/env bash
#
# install.sh — copy an unpacked FFmpeg prefix into a destination prefix.
#
# Usage: install.sh INDIR OUTDIR
#
# Expects the flattened layout produced by variants/linux-install-*.sh, i.e.
# doc/, man/ and presets/ at the top level of the prefix. The .pc files in
# that layout are already rewritten to a relocatable prefix.
#
set -e

if [[ $# -ne 2 ]]; then
    echo "Usage: install.sh INDIR OUTDIR"
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

mkdir -p "${OUTDIR}/presets"
cp -a "${INDIR}"/presets/* "${OUTDIR}"/presets

# Refresh the dynamic linker cache. Only root can write /etc/ld.so.cache, and
# it is only useful when installing into a system library directory, so skip it
# otherwise instead of failing with a confusing permission error.
if [[ $EUID -eq 0 ]]; then
    ldconfig
else
    echo "Note: not running as root, skipping ldconfig."
    echo "      Add ${OUTDIR}/lib to your linker search path if the libraries are not found."
fi
