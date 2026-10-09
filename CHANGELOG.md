# Changelog

## Unreleased developer preview

The macOS preview connects Metal game sessions, app operations, Xcode builds,
and selected Apple profiler evidence in Logfire.

- The Swift SDK exports directly through OpenTelemetry. It includes async spans,
  raw frame histograms, drawable presentation observations, and responsiveness probes.
- The native companion provides source installation, configuration checks, build
  correlation, app-owned scenarios, and targeted Apple CPU, GPU, and shader analysis.
- Apple Metal Overview provides the first investigation view. Apple Development
  Workflow retains the detailed evidence panels.
- An opt-in audit runs repeated reference workloads and a longer onscreen session.
  It retains local evidence for reconciliation with hosted records and metrics.
- Trace export retries one eligible HTTP request inside its original timeout.
  App export health distinguishes HTTP retries from failed span and metric exports.

The tested developer workflow uses macOS 27 and Xcode 27 on Apple Silicon.
The SDK declares macOS 14 and iOS 17 support. Physical iOS delivery remains unverified.
Complete hosted CPU Profiles remains a separate experiment. It is not required
for the preview's CPU summaries, traces, metrics, or dashboards.

There is no stable API guarantee, signed binary installer, or release tag yet.
