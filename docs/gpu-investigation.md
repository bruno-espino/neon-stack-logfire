# Diagnose a GPU workload without a supplied cause

This experiment checks whether telemetry can guide an independent reader to expensive rendering work.
It uses two existing Log Roll particle settings. This is a controlled configuration change, not a newly discovered game defect.
It does not establish community demand, a reproducible performance regression, or time saved by a developer.

## Procedure and scope

Run the same Release binary with the same seed and two-maze/loss assertions.
Trial A uses 65,536 particles. Trial B uses 1,048,576 particles.
Keep the default 20-second application deadline. Collect one unprofiled run per trial.
Freeze an anonymous packet with SDK windows, build identity, assertions, and measurement definitions.
Ask a fresh reader to classify the investigation and cite measurements. Supply no source, fault label, or setup history.
Particle count remains visible because it is legitimate runtime context.

Capture one native GPU workload in a separate launch matching B.
Add its selected replay measurements to an identical SDK packet.
Ask another fresh reader the same question. Do not share the first reader's answer.
Score supported subsystem selection, shader attribution, measurement scope, uncertainty, and the next useful capture.
An honest abstention is acceptable. Invented utilization, presentation failures, or blocking resources fail the check.

Both readers used the same GPT model family. They independently read only their supplied files.
This controls setup disclosure, but does not establish model diversity or general diagnostic accuracy.
Native capture timing differs from the unprofiled trials. Its measurements are excluded from baseline comparisons.
Other desktop activity and uncontrolled cache state can affect these single-run values.

## Verified case on October 7, 2026

Both trials passed with two mazes, 60 moves, four turns, and a loss after 11.741667 simulation seconds.
They used one Release binary at 1688 by 1055 pixels on an Apple M4 with Xcode 27 and macOS 27.
The build ID was `5854c292-58a3-4256-b875-9762fc000209`. Its source fingerprint starts with `d590444c2ca9`.
The [measurement snapshot](../examples/neon-stack/evidence/gpu-blind-case.json) records both trials and the native selection.

| Evidence and scope | Trial A | Trial B |
| --- | ---: | ---: |
| Renderer callback FPS in a complete SDK window | 60.0083 | 50.9547 |
| Callback interval p95 in milliseconds | 17.3708 | 34.6493 |
| Callback intervals above 25 ms | 0 of 301 | 52 of 259 |
| GPU command-duration sum p95 in milliseconds | 22.7514 | 71.9912 |
| Preparation wall-time p95 in milliseconds | 0.3738 | 0.3571 |
| Main-thread CPU, two five-second windows, fraction of one core | 0.0854, 0.0903 | 0.0968, 0.0782 |

The SDK-only reader selected a GPU investigation and left scheduling delays unresolved. It did not name a shader.
The expanded reader named `rollParticleFragment` and `rollParticleVertex` from the separate native capture.
Their replay shader cost fractions were 54.57% and 26.03%.
The `MazeFloorWallsLogFire` encoder had a replay duration of 26.0059 ms and an encoder cost fraction of 89.57%.
Encoder and shader scopes overlap. Do not add their costs or compare replay duration with live callback latency.
The readers both requested a synchronized Metal System Trace to connect GPU submissions, presentation, and CPU scheduling.
Neither reader claimed a blocked resource, GPU saturation, or a reproducible regression.

Logfire queries reproduced both trials' callback, GPU command, particle, and CPU values.
All six native replay records matched the retained manifest's scopes and numeric values.
The SDK and native records shared the matching session trace and build ID.
Raw captures stayed local. Encoder labels have outer quotes in local JSON. Logfire returns their string contents.

## Reproduce the collection

Build a Release app through the [CPU case's build command](cpu-investigation.md#run-the-case).
Run these optional commands from the repository root.

```sh
logfire-apple run --app "$PWD/tmp/DerivedData-macos/Build/Products/Release/NeonStack.app" \
  --scenario examples/neon-stack/scenarios/log-roll-two-mazes.json --output "$PWD/tmp/gpu-case-a"
logfire-apple run --app "$PWD/tmp/DerivedData-macos/Build/Products/Release/NeonStack.app" \
  --scenario examples/neon-stack/scenarios/log-roll-gpu-high.json --output "$PWD/tmp/gpu-case-b"
logfire-apple run --app "$PWD/tmp/DerivedData-macos/Build/Products/Release/NeonStack.app" \
  --scenario examples/neon-stack/scenarios/log-roll-gpu-high.json --profile gpu --output "$PWD/tmp/gpu-case-native"
logfire-apple diagnose --report /absolute/path/to/retained/report.json
```

The local report now includes bounded `diagnostic.gpuReplays` evidence alongside CPU callers and paths.
Agents can inspect those selected GPU nodes without opening a separate manifest or decoding the raw capture.
Each node retains its encoder or shader scope. Capture identity, device, selection method, and replay settings remain attached.
The hosted overview stays small because Logfire already has separate `game.gpu.replay` records.
No new command, profiler, Simulator run, or CI job enters the normal development check.

## What remains unproven

One run per trial cannot establish variability. The particle counts differ, so these are not equivalent rendering workloads.
We deferred a five-pair comparison because this experiment measures evidence sufficiency, not an optimization gain.
GPU replay identifies expensive captured work. It cannot explain individual live main-queue stalls.
The separate native launch reported about 57.19 callback FPS. Do not substitute it for B's unprofiled measurement.
Its application ran for 12.24 seconds. Offline analysis took another 32.22 seconds after the application stopped.
The next validation should use another developer's game and a fault selected without telling the diagnosing agent its cause.
Before claiming a performance improvement, collect repeated matched workloads and report variability and failures.

Apple recommends timeline correlation and structured native output in its [current Metal game workflow](https://developer.apple.com/videos/play/wwdc2026/388/).
