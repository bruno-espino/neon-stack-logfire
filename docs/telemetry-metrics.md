# Native development telemetry

The configured SDK publishes native OTLP metrics every five seconds and on flush.
The companion uses the same exporter for builds and host samples.
The Swift exporter sends both OTLP paths directly over HTTPS. Python and relay tooling are retired.
Previously ingested prototype measurements can remain in Logfire under their original names.

## Instrument catalog

| Instrument | Type and unit | Meaning |
| --- | --- | --- |
| `game.frame.interval` | Delta histogram, ms | Raw renderer callback intervals in full and partial windows |
| `game.renderer.preparation` | Delta histogram, ms | Timed rendering preparation; does not cover all main-thread work |
| `game.gpu.commands.duration` | Delta histogram, ms | Raw Metal command durations; `gpu_time.scope` distinguishes a buffer from a sum |
| `game.frame.count` | Delta counter | Number of retained frame observations |
| `game.frame.over_25ms.count` | Delta counter | Retained intervals above 25 ms |
| `game.render.callback_fps` | Gauge, frames/s | Callback cadence from retained renderer samples |
| `game.display.present.interval` | Delta histogram, ms | Intervals between valid Metal drawable presentation timestamps |
| `game.display.present.count` | Delta counter | Confirmed drawable presentation timestamps |
| `game.display.presented_fps` | Gauge, frames/s | Cadence from positive presentation intervals |
| `game.display.present.lateness` | Delta histogram, ms | Nonnegative lateness when the caller supplies a target presentation time |
| `app.main_queue.delay` | Delta histogram, ms | Completed probe delays, including waits and CPU work |
| `app.main_queue.pending_age.max` | Gauge, ms | Maximum unfinished-probe age in a five-second window |
| `app.main_thread.cpu.utilization` | Gauge, ratio | Main-thread CPU seconds divided by wall seconds |
| `app.process.cpu.utilization` | Gauge, ratio | Process CPU seconds divided by wall seconds; can exceed 1 |
| `app.process.memory.footprint` | Gauge, bytes | macOS physical process footprint |
| `apple.host.cpu.utilization` | Gauge, ratio | Whole-host CPU load during companion observation |
| `apple.host.memory.nonfree` | Gauge, bytes | Physical memory minus free memory; includes cached memory |
| `apple.build.duration` | Delta histogram, seconds | Observed build command duration |
| `apple.build.count` | Delta counter | Observed build outcomes |

The responsiveness monitor is opt-in. The reference game enables it.
Process CPU and footprint are implemented for macOS. Physical iOS behavior is not verified.
Host measurements require a companion build, run, test-game, or attach command.
A plain Cmd-R launch exports app measurements but does not start a host observer.
Metric delivery counts describe exported instruments, not individual frame observations.
The development exporter has no durable offline queue.

Frame metrics use raw observations, not averages of window percentiles.
Warm-up is excluded. Graceful flushes and context changes retain partial windows. Each window retains at most 10,000 observations.
Histogram quantiles are estimates within configured buckets.
Window logs retain exact window percentiles and the sample-limit flag.
Frame histogram exemplars carry the corresponding report's trace context.
A 25 ms slow-frame threshold is fixed. It is not the display's refresh budget.

Session and build identity live on resources. Functions and shader names stay in diagnostic logs.
Metric labels allow only rendering mode, workload, GPU scope, build configuration/cache state, and outcome.
Dashboard queries preserve service name, namespace, environment, instance, and label identity.
They use `metric_*` functions on `value`. They do not decode histogram buckets directly.

## Dashboard and investigation

The reusable [dashboard](../dashboards/apple-development.json) has 28 panels.
It includes frame distributions, slow-frame share, CPU activity, queue delays, GPU stages, build task totals, caller paths, diagnoses, and shader compiler updates.
The inclusive CPU caller table aggregates functions across different sampled paths. Its overlapping weights are not additional metrics or wall time.
Select a Session to inspect one run. Select its Build to inspect the associated build.
New metric queries select `logfire.metric_schema.version=1` to exclude incompatible early experiments.
Capture summaries and live measurements remain separate.

The [15-panel overview](../dashboards/apple-metal-overview.json) restores build timing, task totals, host load, queue delay, and gameplay events beside the SDK charts.
Its session window table links directly to runtime records and the associated build trace.
Both templates retain five-second buckets and UTC measurement timestamps.
SDK log charts use the measured window end. OTel metric charts use collection timestamps.
A flush can put two exports in one bucket. Window logs retain the original measurement interval.
Dots keep isolated observations visible. Distinct app sessions remain separate series.
Use a short time range for detail. Each chart returns at most 10,000 recent rows across its series.
The overview refreshes every five seconds when its Live control is enabled.
A stopped app produces no new observations. Refreshing its dashboard does not extend that session.

Start with callback interval and slow-frame share.
If queue delay rises, compare main-thread CPU with process CPU.
High main-thread CPU suggests a Time Profiler investigation.
Low CPU with high delay suggests waits or scheduling. Time Profiler cannot identify those waits by itself.
For GPU investigations, compare the recorded stage summaries and captured encoder/shader costs.
Replay costs rank a captured workload. They do not measure live GPU utilization or frame-on-glass latency.
Use SDK presentation observations for live onscreen cadence. Native captures still explain drawable waits and frame timelines.
Build task totals can overlap. They do not measure critical-path latency.

Shader compiler evidence uses diagnostic records, not new OTel instruments.
`shader_compiler_update` rows contain native update counts and `shader_compilation_seconds`.
The dashboard converts compiler seconds to milliseconds beside the native window's maximum frame-on-glass interval.
These coarse windows show co-occurrence. They do not establish which exact frame stalled or prove causation.
`*_total` fields are cumulative snapshots. Do not sum them across windows, layers, or captures.
Overview delta fields describe the final update and are omitted from capture summaries.
Missing compiler fields remain absent. Pipeline reuse can avoid compiler events without reporting a cached compiler event.

## Verified experiments

Logfire MCP queries confirmed all fifteen instruments after native export.
A Release Log Roll run completed two mazes and the expected loss in about 12.5 seconds.
Its complete renderer window contained 302 observations in both the retained report and ingested histograms.
Its exact callback p95 was 17.61 ms. The histogram estimate was 17.73 ms.
Preparation p95 was 0.77 ms. The summed GPU-stage p95 was 19.66 ms.
That GPU sum exceeded the callback interval without proving a missed presentation deadline.
The independent CPU window reported about 15% main-thread and 24% process activity relative to one core.
A startup queue delay reached 250 ms. A percentile alone hid much of that rare delay.
These runs verify interpretation and transport. They are not controlled performance baselines.

The [controlled probe](../examples/responsiveness-probe) compared a main-thread sleep with a CPU loop.
Both lasted 1.2 seconds and produced about 1.2 seconds of queue delay.
The sleep window reported 0.034% main-thread activity. The CPU window reported 23.6%.
The pending-age maximum remained visible after the probe completed.
This distinction directs further analysis toward CPU work or waits.

A staged GPU run completed gameplay in 12.1 seconds and analyzed replay afterward for 25.2 seconds.
All selected records joined the run trace in Logfire.
The captured scene encoder represented about 80% of replay cost and 3.44 ms of replay duration.
The particle fragment shader represented about 30% of shader cost, with zero reported spilled bytes.
Encoder and shader rankings describe different scopes. Their percentages must not be added together.
A 262,144-particle scenario timed out even without profiling.
That heavier case needs its own workload budget. We did not increase the default test deadline to hide it.

## CPU recording and offline analysis

`run --profile cpu` requests Time Profiler samples from the ready app.
The companion continues host sampling through the recording command's existing poll callback.
The runner then stops and reaps the app.
The companion exports XML from the saved recording, validates the original PID and actual interval, and publishes the selected CPU summary.
The original session/build identity, binary hash, and available symbols remain attached.

The live experiment returned 854 running samples and twenty ranked leaf functions.
It retained eleven host samples inside the recording span. The largest host sampling gap was 1.05 seconds.
The recording command took 11.3 seconds, including setup and artifact finalization.
Its actual recording interval was 5.83 seconds for a five-second request.
The app lifetime was 18.9 seconds. Offline analysis took another 4.2 seconds.
Both phase spans and all selected function logs joined the run trace in Logfire.
These timings come from one development Mac. They are not guaranteed timing budgets.

The scenario and CPU profile tables expose app lifetime, recording-command cost, actual recording duration, and offline-analysis cost separately.
The scenario deadline remains twenty seconds. Incomplete requested evidence returns an observation gap rather than a fabricated successful profile.
Standalone `profile` still leaves the manually launched app running.
Profiling and decoding remain optional. Ordinary development checks do not invoke either phase.

Drawable presentation requires `FrameRecorder.observe` before presentation, plus normal renderer recording.
Offscreen workloads omit presented FPS. Missing callbacks do not prove dropped frames.
Callback and presentation handlers can cross a window boundary. Compare whole-session counts for coverage.
Partial windows reach Logfire and local reports. Regression inputs retain full windows only.

The native presentation probe verified gzip export against Logfire on 2026-10-08.
Its two full windows and final partial window contain 612 callback samples and 612 confirmed presentations.
Logfire queries return 612 frame histogram samples, 612 presentation counter observations, and 611 presentation interval samples.
The first presentation starts the interval series. Thus, 612 timestamps yield 611 intervals.
These counts verify observation coverage and transport. The busy-host run is not a performance baseline.

The optional [Metal counter probe](../examples/metal-counter-probe) returned eight stage-boundary timestamps from two passes in one command buffer.
Counter overhead and device fallback remain unverified for the game. The experiment does not change its renderer.
