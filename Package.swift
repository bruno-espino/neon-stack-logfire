// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LogfireSwift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LogfireSwift", targets: ["LogfireSwift"]),
        .executable(name: "logfire-apple", targets: ["LogfireApple"]),
    ],
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", exact: "2.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", exact: "2.6.0"),
    ],
    targets: [
        .target(name: "LogfireSwift", dependencies: [
            .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
            .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
            .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
        ], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "LogfireSwiftTests", dependencies: ["LogfireSwift",
            .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        ]),
        .target(name: "LogfireAppleSupport", dependencies: ["LogfireSwift",
            .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
        ]),
        .executableTarget(name: "LogfireApple", dependencies: ["LogfireAppleSupport"]),
        .testTarget(name: "LogfireAppleTests", dependencies: ["LogfireAppleSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
