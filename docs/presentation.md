# Present the Apple Metal integration

The project packages app instrumentation and selected Apple evidence for a repeatable development investigation.
The Swift package, native companion, and dashboard templates are the reusable offering.
The games demonstrate the integration. They are not the product's only possible consumers.

## Showcase

The [React video](../video/README.md) runs for 67 seconds.
It includes game footage, SDK setup, correlated traces, an illustrative FPS improvement, native CPU/GPU capabilities, and a real Logfire dashboard.
Its 45 → 120 FPS scenario uses simulated figures. It shows an optimization goal, not a measured improvement.
The `CPUCase` composition separately shows the measured 29.0% → 8.1% main-thread CPU comparison.
Its five runs per policy used one Release binary. Warmups and profiler runs are excluded.
The renderer callback rate remained near 60 Hz.

The [CPU case](cpu-investigation.md) retains the method and results.
The video data contains rounded values from that case and one verified native game capture.
It contains no credentials, local paths, or full session IDs.
Game footage uses the existing fixed-clock offscreen recorder. It supplies visuals, not performance measurements.

## Dashboard walkthrough

Import [Apple Metal Overview](../dashboards/apple-metal-overview.json).
Choose a time range that includes the original measurement dates.
The session selector discovers SDK sessions in that range. Leave it on All for recent sessions, or select one session.
The Build filter accepts the exact build ID.
Short session/build prefixes in the overview table are display labels, not filter values.
Use the full IDs from the report or detailed dashboard.

Start with the session table. CPU values weight complete responsiveness windows by their duration.
Callback values average complete renderer-window rates. GPU values select the worst window p95.
A missing CPU value remains empty. It does not mean zero CPU activity.
The table includes instrumented runs and uncontrolled desktop sessions. It is not an automatic comparison of equivalent cohorts.

Expand native evidence to see capture identity and coverage of an SDK investigation window.
Repeated imports remain separate rows. Do not sum them.
Expand metrics only after selecting a session and a short time range.
Short captures can disappear as isolated points in a wide chart bucket. The default overview uses tables for this reason.

Use [Apple Development Workflow](../dashboards/apple-development.json) for the full 28-panel investigation.
It retains original IDs, selected CPU callers, GPU replay nodes, host context, builds, and native capture details.
Raw recordings remain local. The dashboard does not provide a hosted Instruments viewer.

## Trace review on October 8, 2026

Logfire queries verified the current real game run and both of its offline imports.
All SDK windows, game events, host samples, and the run summary in that run have the `development.run` parent.
The build has a separate trace linked by `build.id` and `build.trace_id`.
An offline import has its own `development.timeline.import` operation.
Its resource context retains `source.run_trace_id` for the original run.

| Record | Kind | Meaning |
| --- | --- | --- |
| `xcode.build` | Span | Build command lifetime |
| `development.run` | Span | Scenario runner operation, including optional analysis |
| `development.cpu.record` / `development.cpu.analysis` | Spans | Separate native recording and decoding operations |
| `game.performance.window` | Log | Completed renderer window with measurement dates and scope |
| `app.responsiveness.window` | Log | Independent queue-delay and CPU window |
| `game.host.sample` | Log | Whole-host context from the companion |
| `game.collision` | Log | In-game obstacle collision, not an application crash |
| `game.cpu.caller` | Log | Inclusive running-sample weight within one capture |
| `game.gpu.replay` | Log | Selected captured replay encoder or shader cost |
| `development.thread.window` | Log | Native states clipped to one SDK investigation window |
| `development.metal.drawable_wait` | Log | Complete next-drawable call wall time within the native capture |
| `development.timeline.import` | Span | An explicit offline evidence import |

Historical data retains older span-based summaries and the old `game.crash` collision name.
The overview queries current log-based SDK summaries. It does not reinterpret old data.
The rename changes telemetry terminology in Log Roll and Flappy Log, not gameplay.

Manual Command-R sessions do not have the runner's propagated parent.
Their records correlate through session/build identity. The SDK does not create a session root automatically.
MetricKit reports keep their historical dates and omit current-session identity.
A shared source code revision is insufficient to claim that different workloads form a comparable cohort.

The current automated trace structure is useful for investigation.
The remaining material gaps are native app launch ownership, shared recorder cancellation, full presentation attribution, artifact sharing, and testing on another Mac.
These need validation before a release claim or a fully unattended timeline workflow.

The review follows [Apple's Metal investigation guidance](https://developer.apple.com/videos/play/wwdc2026/388/)
and [Logfire's dashboard guidance](https://pydantic.dev/docs/logfire/observe/dashboards/).
The video uses [Remotion's documented rendering workflow](https://www.remotion.dev/docs/cli/render).
