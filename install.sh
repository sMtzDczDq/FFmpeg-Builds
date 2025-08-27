#!/bin/bash
set -e

if [[ "$#" != 2 ]]; then
	printf 'Usage: install.sh INDIR OUTDIR\n'
	exit 1
fi

IN="$1"
OUT="$2"

mkdir -p "${OUT}"/bin || exit 1
cp "${IN}"/bin/* "${OUT}"/bin || exit 1

mkdir -p "${OUT}"/lib || exit 1
cp -a "${IN}"/lib/*.so* "${OUT}"/lib || exit 1

mkdir -p "${OUT}"/lib/pkgconfig || exit 1
cp -a "${IN}"/lib/pkgconfig/*.pc "${OUT}"/lib/pkgconfig || exit 1

mkdir -p "${OUT}"/include || exit 1
cp -r "${IN}"/include/* "${OUT}"/include || exit 1

mkdir -p "${OUT}"/doc || exit 1
cp -r "${IN}"/doc/* "${OUT}"/doc || exit 1

mkdir -p "${OUT}/man" || exit 1
cp -r "${IN}"/man/* "${OUT}"/man || exit 1

ldconfig
