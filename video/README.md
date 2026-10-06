# Logfire × Swift reel

A 67-second video for an internal presentation, built with [Remotion](https://www.remotion.dev): every scene is a React component in `src/scenes/`.
The data on screen (`src/data.json`) comes from real records in the `bruno/mac-observer` Logfire project.

## Record the game footage

The footage is not in Git. Build the app, then record each clip with the offscreen replay. Set `NEON_RECORD` to write an MP4 at a fixed 60 FPS clock.

```sh
APP=examples/neon-stack/tmp/DerivedData-macos/Build/Products/Release/NeonStack.app/Contents/MacOS/NeonStack
F=video/public/footage; mkdir -p $F
env NEON_OFFSCREEN=1 NEON_GAME=log-roll LOG_ROLL_PARTICLES=1048576 NEON_RECORD=$PWD/$F/log-roll.mp4 NEON_RECORD_SIZE=1920x1080 NEON_BENCHMARK_SECONDS=16 $APP
env NEON_OFFSCREEN=1 NEON_GAME=flappy-log FLAPPY_PARTICLES=1048576 NEON_RECORD=$PWD/$F/flappy-log.mp4 NEON_RECORD_SIZE=1920x1080 NEON_BENCHMARK_SECONDS=12 $APP
env NEON_OFFSCREEN=1 NEON_GAME=neon-stack NEON_RECORD=$PWD/$F/log-stack.mp4 NEON_RECORD_SIZE=720x1440 NEON_BENCHMARK_SECONDS=24 $APP
env NEON_OFFSCREEN=1 NEON_GAME=neon-stack NEON_FEEDBACK_SCENARIO=burn NEON_RECORD=$PWD/$F/log-stack-burn.mp4 NEON_RECORD_SIZE=720x1440 NEON_BENCHMARK_SECONDS=4 $APP
```

## Preview and render

```sh
cd video
npm install
npm run studio   # preview in the browser
npm run render   # writes out/logfire-swift-reel.mp4
```

## Music

Scenes start on a 120 BPM grid (one bar is 2 seconds), so a 120 BPM track lines up with the cuts.
Put the track at `public/music.mp3` and add an `<Audio>` element to `Reel` in `src/Root.tsx`.
