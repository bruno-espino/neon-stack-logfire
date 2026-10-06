# Native development telemetry

The configured SDK publishes native OTLP metrics every five seconds and on flush.
The companion uses the same exporter for builds and host samples.
No Python collector or relay is required. The optional legacy relay forwards both OTLP paths.
Historical Python metrics remain available under their original names.

## Instrument catalog

| Instrument | Type and unit | Meaning |
| --- | --- | --- |
| `game.frame.interval` | Delta histogram, ms | Raw renderer callback intervals in complete windows |
| `game.renderer.preparation` | Delta histogram, ms | Timed rendering preparation; does not cover all main-thread work |
| `game.gpu.commands.duration` | Delta histogram, ms | Raw Metal command durations; `gpu_time.scope` distinguishes a buffer from a sum |
| `game.frame.count` | Delta counter | Number of retained frame observations |
| `game.frame.over_25ms.count` | Delta counter | Retained intervals above 25 ms |
| `game.render.callback_fps` | Gauge, frames/s | Callback cadence from a complete window |
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
Warm-up and incomplete windows are excluded. Each window retains at most 10,000 observations.
Histogram quantiles are estimates within configured buckets.
Window logs retain exact window percentiles and the sample-limit flag.
Frame histogram exemplars carry the corresponding report's trace context.
A 25 ms slow-frame threshold is fixed. It is not the display's refresh budget.

Session and build identity live on resources. Functions and shader names stay in diagnostic logs.
Metric labels allow only rendering mode, workload, GPU scope, build configuration/cache state, and outcome.
Dashboard queries preserve service name, namespace, environment, instance, and label identity.
They use `metric_*` functions on `value`. They do not decode histogram buckets directly.

## Dashboard and investigation

The reusable [dashboard](../dashboards/apple-development.json) has twenty panels.
Its six new panels show frame distributions, slow-frame share, CPU activity, queue delays, GPU stages, and build task totals.
Select a Session to inspect one run. Select its Build to inspect the associated build.
New metric queries select `logfire.metric_schema.version=1` to exclude incompatible early experiments.
Capture summaries and live measurements remain separate.

Start with callback interval and slow-frame share.
If queue delay rises, compare main-thread CPU with process CPU.
High main-thread CPU suggests a Time Profiler investigation.
Low CPU with high delay suggests waits or scheduling. Time Profiler cannot identify those waits by itself.
For GPU investigations, compare the recorded stage summaries and captured encoder/shader costs.
Replay costs rank a captured workload. They do not measure live GPU utilization or frame-on-glass latency.
Use native presentation captures to investigate drawable waits and actual presentation timing.
Build task totals can overlap. They do not measure critical-path latency.

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
