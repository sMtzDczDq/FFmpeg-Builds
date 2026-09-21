#!/usr/bin/env bash
set -xeo pipefail
cd "$(dirname "$0")"
source util/vars.sh

docker buildx create --bootstrap --name ffbuilder --config .github/buildkit.toml --driver-opt network=host --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=-1 --driver-opt env.BUILDKIT_STEP_LOG_MAX_SPEED=-1

skopeo copy docker://ghcr.io/btbn/ffmpeg-builds/win64-gpl-shared-8.1:latest docker-daemon:ghcr.io/btbn/ffmpeg-builds/win64-nonfree-8.1:latest
