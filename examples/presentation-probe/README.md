# Drawable presentation verification

This opt-in macOS example creates a small Metal window for twelve seconds.
It reports actual drawable presentation timestamps and completed renderer callbacks.
It pauses rendering, drains the GPU queue, publishes the partial window, and flushes before exit.
It does not run in the default development check.

Use the repository's Xcode 27 build products:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun swift build --product LogfireSwift
products=$(xcrun swift build --show-bin-path)
xcrun swiftc -I "$products" examples/presentation-probe/main.swift \
  "$products/libLogfireSwift.a" -o /tmp/logfire-presentation-probe
LOGFIRE_DEV_DIRECT=1 /tmp/logfire-presentation-probe
```

Configure the development write token first with `logfire-apple configure`.
The example reads runtime credentials. It does not embed them in the binary.
Query `game.performance.window` for the printed session ID.
Compare `display_presented_fps` with `render_callback_fps`.
Check `game.display.present.count` and `game.display.present.interval` for raw observation coverage.
The example measures transport and API behavior. Its frame rates are not a controlled performance baseline.
