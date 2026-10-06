// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LogfireSwift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LogfireSwift", targets: ["LogfireSwift"])],
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift.git", exact: "2.6.0"),
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", exact: "2.6.0"),
    ],
    targets: [
        .target(name: "LogfireSwift", dependencies: [
            .product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"),
            .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
            .product(name: "OpenTelemetryProtocolExporterHTTP", package: "opentelemetry-swift"),
        ]),
        .testTarget(name: "LogfireSwiftTests", dependencies: ["LogfireSwift",
            .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
