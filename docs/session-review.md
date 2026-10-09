# Review Apple Metal sessions in Logfire

The project packages app instrumentation and selected Apple evidence for a repeatable development investigation.
The Swift package, native companion, and dashboard templates are the reusable offering.
The games demonstrate the integration. They are not the product's only possible consumers.

## Dashboard walkthrough

Import [Apple Metal Overview](../dashboards/apple-metal-overview.json).
Choose a time range that includes the original measurement dates.
The session selector discovers SDK sessions in that range. Leave it on All for recent sessions, or select one session.
The Build filter accepts the exact build ID.
Short session/build prefixes in the overview table are display labels, not filter values.
Use the full IDs from the report or detailed dashboard.

Start with the session table. CPU values weight observed responsiveness windows by their duration.
Callback and presented rates divide observation counts by their elapsed time.
The table includes partial tails and shows complete versus all renderer-window counts.
Presented FPS stays empty when the app does not observe drawables.
A missing CPU value remains empty. It does not mean zero CPU activity.
The table includes instrumented runs and uncontrolled desktop sessions. It is not an automatic comparison of equivalent cohorts.

The overview has 12 panels and starts with the last 15 minutes.
Live app measurements starts open. It shows callback versus presented FPS, slow-frame share, CPU activity, and queue delay.
Expand Events and trace drilldown for gameplay events and session window records.
Open `trace_id` or `span_id` for the runtime evidence. Open `build_trace_id` for the associated Xcode build.
These links avoid copying an ID into another filter. An absent build trace remains empty.
A narrow app interval can exclude an earlier build from the build table. Its trace link opens independently of that interval.
Builds and host context shows build duration and whole-host CPU load. Detailed task totals remain in Apple Development Workflow.
The build table ignores Session. Use Build to select one build across the dashboard.

Expand Native investigation to see capture identity and coverage of an SDK investigation window.
Repeated imports remain separate rows. Do not sum them.
Charts use five-second buckets and visible points. UTC timestamp casts align callback, host, and CPU observations.
Select a session and zoom to seconds or minutes. Short captures remain visible as dots in a day-wide view.
The dashboard requests a five-second refresh. Logfire controls the actual refresh cadence for the selected range. A stopped session does not produce a continuous feed.

Use [Apple Development Workflow](../dashboards/apple-development.json) for the full 28-panel investigation.
It retains original IDs, raw frame distributions, selected CPU callers, GPU replay nodes, task totals, and native capture details.
Detailed groups start collapsed. Expand the evidence needed for the current question.
Its session selector also discovers native-only imports that have no SDK window.
Raw recordings remain local. The dashboard does not provide a hosted Instruments viewer.

The browser review found one older diagnostic run with three completed frame logs but only two ingested histogram batches.
Its retained report records a runner-requested stop and no acknowledged export failures.
This shows that delivery counters alone do not prove complete metric coverage.
The exact shutdown cause remains unverified. The exporter has no durable offline queue.

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
CPU recording now shares cancellation with its app and decoding commands. Native interruption checks cover recording and post-app finalization.
The remaining material gaps are native app launch ownership, concurrent GPU/System Trace cancellation, full presentation attribution, artifact sharing, and testing on another Mac.
These need validation before a release claim or a fully unattended timeline workflow.

The review follows [Apple's Metal investigation guidance](https://developer.apple.com/videos/play/wwdc2026/388/)
and [Logfire's dashboard guidance](https://pydantic.dev/docs/logfire/observe/dashboards/).

## Developer preview audit on October 9, 2026

The audit ran five interleaved repetitions of five policies and one 60-second onscreen session.
The policies cover normal presentation, half-rate presentation, bounded HUD updates,
every-frame HUD updates, and increased GPU work.
These runs test coverage and deliberate policies. The busy development Mac is not a clean performance baseline.

All 26 scenario assertions passed. Local reports retain 77 renderer windows and 17,986 frame samples.
Hosted queries reproduce every window, frame counter, GPU sample, and presentation interval.
Each session's frame records use its expected `development.run` trace.
The five normal/half-rate pairs distinguish approximately 60/60 from 60/30 callback/presentation rates.
The longer run supplies 11 complete windows and retained partial windows for a readable continuous timeline.

The dashboard audit executes all 34 unique queries across both templates.
The compact overview replaces duplicate profiler tables with a focused first view.
The investigation dashboard retains all 28 detailed panels. Missing capture data stays empty.
The gameplay table now includes input spans and `game.maze.cleared` outcomes.
Selected-session callback legends omit the long UUID. Metric legends use source numbers while grouping by every source dimension.
Source numbers describe identities within one query. They are not persistent IDs or labels to compare across panels.
Apple layer charts exclude older rows with no native interval timestamp.

The Release build's 125 records reached Logfire. One Debug-build host sample did not arrive.
The Debug build trace and all 12 task summaries arrived. Its report retains the failed export count.
This audit keeps that loss visible. It does not substitute the successful build outcome for delivery completeness.

Run another audit after changing the SDK export, scenario shutdown, or dashboard SQL:

```sh
tools/check-presentation.sh
tools/check-preview.sh --app PATH_TO_APP --probe PATH_TO_PRESENTATION_PROBE --repeat 5
```

Use the probe path printed by the first command and an already-built reference game.
`--repeat 1` reduces the short cases. The continuous case still lasts 60 seconds.
`--no-telemetry` keeps the audit local. Default development checks remain short.
The private audit directory retains every case, failures, presentation checks, and a machine-readable summary.
Reconcile it with hosted records and metrics before claiming complete delivery.

Targeted GPU replay and retained shader analysis also passed. Their selected evidence reached Logfire.
A short CPU-profile run exhausted its app deadline before Instruments finalized. The report remains incomplete with exit 2.
A separate 60-second diagnostic session completed CPU recording, decoding, and export.
Live attach collected 26 Apple layer and process records during that session.
CPU analysis exported one profile summary, 20 leaf functions, 40 inclusive callers, and 40 caller paths.
These targeted runs validate the evidence paths. Their profiler overhead prevents baseline comparisons.
The CPU lifecycle follow-up records beside app polling and finalizes after app reaping.
A rebuilt-app warm run completes with the existing 20-second app deadline. Late readiness can still miss attachment and return incomplete evidence.
The two older hosted dashboards now carry a Legacy label. Their links remain available.

An additional six-case local-only audit passes with disabled exporters. It retains 6,351 frame samples and uploads no telemetry.

Queries also find 18 distinct metric instruments in this audit interval. Four describe companion builds or host context; 14 describe the app.
Detailed CPU callers, GPU replay costs, and shader compiler updates remain structured records, not additional live metric instruments.
The presentation-lateness instrument has no observations because these workloads do not supply presentation target times.
The interruption check returns exit 130, stops the owned app, and starts no subsequent case.

### Which panels proved useful

The five repetitions produce these medians on the busy development Mac.
They demonstrate signal sensitivity. They do not establish a release performance baseline or a measured speedup.
CPU values describe the identified main thread relative to one core.

| Deliberate policy | Callback Hz | Presented FPS | Main-thread CPU % | What the overview reveals |
| --- | --- | --- | --- | --- |
| Normal drawable submission | 60.0 | 59.9 | 1.3 | Callback and presentation cadence agree |
| Every second drawable submission | 60.0 | 30.0 | 1.1 | Callback cadence alone hides the presentation limit |
| Log Roll with bounded HUD updates | 60.0 | 60.0 | 6.5 | The app retains headroom while it presents normally |
| Log Roll with every-frame HUD updates | 60.0 | 60.0 | 28.9 | Extra main-thread work is visible even before FPS drops |
| Log Roll with increased GPU work | 52.8 | 52.1 | 5.9 | Cadence falls without a similar rise in main-thread CPU |

Keep the four overview charts. Each answers a different first investigation question.
Keep raw distributions, native CPU callers, GPU replay costs, shader updates, and wait coverage in the detailed dashboard.
Those panels answer targeted questions after collection. They are not continuous feeds from an ordinary app launch.
No third dashboard is needed for this preview. Independent tester feedback should guide the next addition.
