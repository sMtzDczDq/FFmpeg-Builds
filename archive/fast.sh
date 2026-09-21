#!/usr/bin/env bash
set -xeo pipefail
cd "$(dirname "$0")"
source util/vars.sh

docker buildx create --bootstrap --name ffbuilder --config .github/buildkit.toml --driver-opt network=host --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=-1 --driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=-1

./generate.sh "$TARGET" "$VARIANT" "${ADDINS[@]}"

./download

docker buildx --builder ffbuilder build --cache-from=type=local,src=.cache/ghcr.io/btbn/ffmpeg-builds/$TARGET-$VARIANT-8.1_latest --cache-to=type=local,mode=max,dest=.cache/ghcr.io/btbn/ffmpeg-builds/linux64-nonfree-shared-8.1_latest --build-context ghcr.io/btbn/ffmpeg-builds/base-linux64:latest=docker-image://ghcr.io/btbn/ffmpeg-builds/base-linux64:latest --load --tag ghcr.io/btbn/ffmpeg-builds/linux64-nonfree-shared-8.1:latest .
