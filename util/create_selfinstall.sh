#!/usr/bin/env bash
#
# create_selfinstall.sh — turn a shared linux tarball into a self-extracting
# installer script.
#
# Usage: create_selfinstall.sh artifacts/ffmpeg-*linux64-nonfree-shared-*.tar.xz
#
set -euo pipefail
IFS=$'\n\t'

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" ]]; then
    printf 'Usage: create_selfinstall.sh artifacts/ffmpeg-*linux64-nonfree-shared-*.tar.xz\n'
    exit 1
fi
if [[ ! -f "$ARCHIVE" ]]; then
    printf 'error: no such file: %s\n' "$ARCHIVE" >&2
    exit 1
fi
# Only shared linux builds make sense here: the self-extractor unpacks the
# tarball into /usr/local, which needs the shared libraries and headers.
# The archive is named ffmpeg-<version>-<target>-<variant>.tar.xz, e.g.
# ffmpeg-n9.0.2-30-g20339a85af-linux64-nonfree-shared.tar.xz — note that
# "-shared" is immediately followed by ".tar.xz", so this needs '.*' and
# not '.+' between them.
if [[ ! "$ARCHIVE" =~ linux.+-shared.*\.tar\.xz$ ]]; then
    printf 'This script only works for shared linux builds\n'
    exit 1
fi

OUTPUTFILE="${ARCHIVE%.tar.xz}.sh"

SELFINSTALLTEMPLATE="#!/usr/bin/env bash
# https://stackoverflow.com/a/29418549
# a self-extracting script header

# determine the line number of this script where the payload begins
PAYLOAD_LINE=\$(awk '/^__PAYLOAD_BELOW__/ {print NR + 1; exit 0; }' \"\$0\")

# use the tail command and the line number we just determined to skip
# past this leading script code and pipe the payload to tar
tail -n+\"\$PAYLOAD_LINE\" \"\$0\" | sudo tar --strip-components=1 --keep-directory-symlink --no-same-owner -xJv -C /usr/local

# The .pc files were generated with --prefix=/ffbuild/prefix, a path that only
# exists inside the build container. Point them at the real install prefix.
for pc in /usr/local/lib/pkgconfig/*.pc; do
    [ -f \"\$pc\" ] || continue
    awk '
        /^prefix=/     { print \"prefix=/usr/local\";           next }
        /^libdir=/     { print \"libdir=/usr/local/lib\";        next }
        /^includedir=/ { print \"includedir=/usr/local/include\"; next }
        { print }
    ' \"\$pc\" > \"\$pc.new\"
    mv -f \"\$pc.new\" \"\$pc\"
done

sudo ldconfig

# now we are free to run code in output_dir or do whatever we want

exit 0

# the 'exit 0' immediately above prevents this line from being executed
__PAYLOAD_BELOW__"

printf '%s\n' "$SELFINSTALLTEMPLATE" >"$OUTPUTFILE"
cat "$ARCHIVE" >>"$OUTPUTFILE"

chmod 0755 "$OUTPUTFILE"
