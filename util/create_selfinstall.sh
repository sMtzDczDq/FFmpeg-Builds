#!/usr/bin/env bash
set -x

if [[ -f "$1" ]]; then
	if grep --perl-regexp 'linux.+-shared.+\.tar.xz' <<<"$1"; then
		FFARCHIVE="$1"
	else
		printf 'This script only works for shared linux builds\n'
		exit 1
	fi
else
	printf 'Usage: create_selfinstall.sh artifacts/ffmpeg-*linux64-nonfree-shared-*.tar.xz\n'
	exit 1
fi

OUTPUTFILE="${FFARCHIVE%/*}"/"$(basename "$FFARCHIVE" .tar.xz)"".sh"

SELFINSTALLTEMPLATE="#!/bin/bash
# https://stackoverflow.com/a/29418549
# a self-extracting script header

# determine the line number of this script where the payload begins
PAYLOAD_LINE=\$(awk '/^__PAYLOAD_BELOW__/ {print NR + 1; exit 0; }' \"\$0\")

# use the tail command and the line number we just determined to skip
# past this leading script code and pipe the payload to tar
tail -n+\"\$PAYLOAD_LINE\" \"\$0\" | sudo tar --strip-components=1 --keep-directory-symlink --no-same-owner -xJv -C /usr/local
sudo ldconfig

# now we are free to run code in output_dir or do whatever we want

exit 0

# the 'exit 0' immediately above prevents this line from being executed
__PAYLOAD_BELOW__"

echo "$SELFINSTALLTEMPLATE" >"$OUTPUTFILE"
cat "$FFARCHIVE" >>"$OUTPUTFILE"

chmod +x "$OUTPUTFILE"
