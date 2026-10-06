# Controlled responsiveness experiment

Run this example only on a trusted development Mac.
The example exports to the configured development project.
It observes a quiet window, a 1.2-second main-thread sleep, and a 1.2-second CPU loop.
The example ends after about 17 seconds.
It does not run in the ordinary development check.

Xcode 27's Swift package build produces a static library and its dependencies.
From the repository root, use the same build products for this small example.

```sh
swift build
products=$(swift build --show-bin-path)
swiftc -I "$products" examples/responsiveness-probe/main.swift \
  "$products/libLogfireSwift.a" -o /tmp/logfire-responsiveness-probe
LOGFIRE_DEV_DIRECT=1 /tmp/logfire-responsiveness-probe
```

Query `app.responsiveness.window` for the printed session ID.
The sleep should increase main-queue delay with little main-thread CPU activity.
The CPU loop should increase both queue delay and CPU activity.
CPU ratios average five-second windows, so a 1.2-second loop does not produce a full-window ratio of 1.
The probe uses the main run loop to keep the main thread alive.
