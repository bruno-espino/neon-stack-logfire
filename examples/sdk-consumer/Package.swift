// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LogfireApplePilot",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/bruno-espino/neon-stack-logfire.git",
            revision: "c46b09dcaeeee9843db2e05bf4dce042681e8168")
    ],
    targets: [
        .executableTarget(name: "LogfireApplePilot", dependencies: [
            .product(name: "LogfireSwift", package: "neon-stack-logfire")
        ])
    ],
    swiftLanguageModes: [.v6]
)
