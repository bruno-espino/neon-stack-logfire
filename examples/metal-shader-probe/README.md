# Metal shader evidence probe

This small MetalKit app imports no Logfire Swift SDK.
It implements the runner's session marker and readiness/completion handshake directly.
The companion supplies host samples, Apple measurements, trace correlation, and export.
This example does not prove support for an arbitrary uninstrumented game.
The Swift SDK remains the normal integration for app operations, frame windows, responsiveness, and rendering state.

Use macOS 27 and Xcode 27. From the repository root, run:

```sh
examples/metal-shader-probe/build.sh
logfire-apple run --app tmp/MetalShaderProbe.app \
  --scenario examples/metal-shader-probe/scenario.json --profile shader
```

The app creates a new runtime shader pipeline at two seconds.
It recreates that pipeline at five seconds and creates a second new pipeline at eight seconds.
It publishes completion at eleven seconds. The runner then analyzes Apple's retained shader timeline.
The build script embeds identity. It does not create an observed Xcode build trace.
Add `--no-telemetry` for a local experiment.

The private run directory contains pipeline-call wall timings, the scenario report, and a capture manifest.
The dashboard's shader table shows compiler updates beside native presentation measurements.
Unique function names reduce cache reuse between runs without flushing the machine's shader cache.
Pipeline reuse can avoid compiler events entirely. A zero cached-event count does not prove a cache miss.
HUD instrumentation adds its own pipelines. Use this probe for evidence validation, not a clean performance baseline.

See [the native workflow](../../docs/native-workflow.md#run-an-app-owned-scenario) for attribution, timing, and export limits.
