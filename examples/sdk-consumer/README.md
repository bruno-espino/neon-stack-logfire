# SDK-only consumer

This independent Swift 6 package imports only the public `LogfireSwift` product.
It pins the reviewed SDK revision from PR #19.
Its executable sends an async operation and child event, then verifies two acknowledged exports.
It does not link the companion or game.

Configure this Mac through [the main setup path](../../README.md#configure-this-mac), then run:

```sh
cd examples/sdk-consumer
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  LOGFIRE_DEV_DIRECT=1 xcrun swift run -j 2 LogfireApplePilot
```

The first build resolves the public package and its dependencies into a separate build directory.
The executable prints its session ID and a Live View filter.
It reads the private runtime credential file. It does not embed the token.
Compilation on this Mac does not verify another Mac's toolchain or setup.

On a second tester Mac, check the following before a wider pilot:

1. Install the companion, configure that Mac's project write token, and run `doctor --send`.
2. Run this executable with `LOGFIRE_DEV_DIRECT=1`. It must acknowledge exactly two records.
3. Query its printed session in Logfire. `pilot.loaded` must share `pilot.load`'s trace and name it as its parent.
4. Run the reference game with Command-R and select its session in the imported overview dashboard.

The independent package build and parentage check pass on the development Mac.
A second Mac, physical iOS delivery, and real daily MetricKit delivery remain unverified.
