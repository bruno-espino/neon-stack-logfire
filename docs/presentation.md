# Present the Apple Metal integration

The [React video](../video/README.md) runs for 77 seconds.
It includes game footage, SDK setup, input spans, correlated traces, native CPU/GPU capabilities, and a real Logfire dashboard.

The input replay illustrates the shipped `game.rotate`, `game.hold`, and `game.drop` operation names.
It shows key presses beside the span rows and nested line-clear feedback.
The sequence and span-bar lengths are illustrative. They are not a recording of the adjacent fixed-clock footage.
Gameplay feedback remains a log within an operation. The video does not change app instrumentation.

The dashboard scene shows an actual ingested Log Roll session.
The [session review](session-review.md) documents the dashboard walkthrough and verified runtime/build/import trace boundaries.
The [telemetry catalog](telemetry-metrics.md) documents measurement scopes.

The 45 → 117 FPS animation shows the collaborator's reported Log Roll fix from 2026-10-06.
Log Roll slowed after each game because every frame invalidated the SwiftUI view tree.
The fix refreshes the surrounding SwiftUI only when displayed values change.
The same automated loop ran before and after: clear two mazes, lose, restart.
After about 15 games, FPS rose from 45 to about 117 and CPU fell from about 100% to about 20%.
That comparison used one run per build. The figures are approximate.
The repository does not retain its original frame reports. This figure does not establish confirmed presented FPS.
The separate `CPUCase` composition shows the measured 29.0% → 8.1% main-thread CPU comparison.
Its five runs per policy used one Release binary. Warmups and profiler runs are excluded.
The renderer callback rate remained near 60 Hz.
The [CPU case](cpu-investigation.md) retains the method and results.

Video data contains rounded values from that case and one verified native game capture.
It contains no credentials, local paths, or full session IDs.
Game footage uses the existing fixed-clock offscreen recorder. It supplies visuals, not performance measurements.
See [Remotion's rendering workflow](https://www.remotion.dev/docs/cli/render) for rendering options.
