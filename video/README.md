# Apple Metal + Logfire showcase

A 67-second React video built with [Remotion](https://www.remotion.dev).
It presents SDK setup, trace correlation, a flashy FPS scenario, native CPU/GPU capabilities, and a real Logfire dashboard.
The shared ember theme and animation components preserve the original reel's visual style.

## Render

```sh
cd video
npm ci
npm run check
npm run render
```

The default render uses the included game poster and dashboard screenshot.
It needs no game build, credentials, or Logfire connection.
The output is `out/logfire-swift-reel.mp4` at 1920 × 1080, 30 FPS.
Rendering uses two workers to limit host load.
Use `npm run studio` to preview the React scenes.
Use `npm run still -- out/performance.png --frame=1040` for a still.

## Use moving game footage

Build the reference game in Release. Run the existing offscreen recorder through this script from the repository root:

```sh
video/record-footage.sh "$PWD/tmp/DerivedData-macos/Build/Products/Release/NeonStack.app"
cd video
npm run render:footage
```

The script records fixed-clock footage at 60 FPS and disables telemetry export.
It generates Log Roll, Flappy Log and Neon Stack clips. The current reel includes all three workloads.
These clips illustrate gameplay. They do not supply the performance figures.
Raw footage and rendered outputs stay outside Git.

## Data and claims

The 45 → 120 FPS animation is labelled **Illustrative optimization scenario** and **simulated figures** on screen.
It shows a capability and target. It does not claim that this prototype measured that improvement.
The `CPUCase` composition shows the separate measured CPU comparison. Render it with `npm run render:cpu`.

`src/data.json` contains the ten measured CPU runs, their medians, and one native next-drawable capture.
Logfire queries reproduced every CPU ratio on October 8, 2026.
The real native capture contains 201 complete calls and 758.5 ms of total wall time.
Its SDK investigation window has 43.7% native coverage and 174.2 ms of overlapping drawable wait time.
The optional `NativeEvidence` composition preserves those scopes. It makes no controlled performance claim from that busy-host capture.

The trace diagram uses the current names and kinds. Operation spans and structured logs are distinct.
The screenshot comes from the real **Apple Metal Overview** dashboard with one ingested Log Roll session.
The current overview also exposes build timing, host load, queue delays, gameplay events, and runtime/build trace links.
It contains no token or local path. Its historical records predate the `game.crash` → `game.collision` naming correction.

See [the presentation and trace review](../docs/presentation.md) and [the measured CPU case](../docs/cpu-investigation.md).
