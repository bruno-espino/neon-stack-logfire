# Metal counter experiment

This optional probe times two render passes in one command buffer.
It uses `MTLCounterSampleBuffer` and stage-boundary timestamp sampling.
The probe checks device support and calibrates GPU timestamps against CPU timestamps.
Unsupported devices print an explicit message.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swiftc examples/metal-counter-probe/main.swift -o /tmp/logfire-metal-counter-probe
/tmp/logfire-metal-counter-probe
```

The experiment returned all eight timestamp samples on an Apple M4.
It proves API access. It does not measure profiling overhead or a game optimization.
The game keeps its existing command-buffer timing until overhead and fallback behavior are verified.
The probe exports no telemetry and stays outside default development checks.

Apple documents [counter sampling](https://developer.apple.com/documentation/metal/sampling-gpu-data-into-counter-sample-buffers)
and [GPU clock conversion](https://developer.apple.com/documentation/metal/converting-gpu-timestamps-into-cpu-time).
