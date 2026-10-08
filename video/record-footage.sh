#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
    printf 'Usage: video/record-footage.sh /absolute/path/NeonStack.app\n' >&2
    exit 2
fi
video_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
executable="$1/Contents/MacOS/NeonStack"
if [ ! -x "$executable" ]; then
    printf 'The app does not contain an executable NeonStack.\n' >&2
    exit 2
fi
mkdir -p "$video_root/public/footage"
# Fixed-clock footage supplies visuals. It is not a performance measurement.
for game in log-roll flappy-log neon-stack; do
    filename=$game
    size=1920x1080
    if [ "$game" = neon-stack ]; then filename=log-stack; size=720x1440; fi
    env LOGFIRE_DEV_DIRECT=0 NEON_OFFSCREEN=1 NEON_GAME="$game" NEON_SEED=777 \
        LOG_ROLL_PARTICLES=65536 FLAPPY_PARTICLES=65536 \
        NEON_RECORD="$video_root/public/footage/$filename.mp4" NEON_RECORD_SIZE="$size" \
        NEON_BENCHMARK_SECONDS=10 nice -n 15 "$executable"
done
