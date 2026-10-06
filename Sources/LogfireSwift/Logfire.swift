import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import os

/// An experimental integration for local Apple development.
public final class Logfire {
    private let tracer: Tracer
    private let provider: TracerProviderSdk?
    private let signposter = OSSignposter(subsystem: "dev.logfire.swift", category: .pointsOfInterest)
    public let sessionID: String
    private let buildAttributes: [String: AttributeValue]
    private let serviceName: String
    private let scenarioID: String?
    private var appleReports: AnyObject?
    private var lifecycle: AppleLifecycle?
    let stateReporterLock = NSLock()
    var stateReporters: [String: AnyObject] = [:]
    private let deliveryCounters = DeliveryCounters()
    public var delivery: DeliveryStatus { deliveryCounters.snapshot(enabled: provider != nil) }

    public convenience init(serviceName: String, configuration: LogfireConfiguration?) {
        self.init(serviceName: serviceName, exporter: configuration?.makeExporter())
    }

    public convenience init(serviceName: String, endpoint: URL? = nil) {
        let exporter = endpoint.map {
            OtlpHttpTraceExporter(endpoint: $0,
                config: .init(timeout: 3, compression: .none, exportAsJson: false),
                envVarHeaders: [], requeueOnFailure: false)
        }
        self.init(serviceName: serviceName, exporter: exporter)
    }

    init(serviceName: String, exporter: SpanExporter?) {
        self.serviceName = serviceName
        scenarioID = ProcessInfo.processInfo.environment["LOGFIRE_SCENARIO_ID"]
        sessionID = (ProcessInfo.processInfo.environment["LOGFIRE_SESSION_ID"] ?? ProcessInfo.processInfo.environment["NEON_SESSION_ID"]).flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
        buildAttributes = Self.buildMetadata(bundle: .main).mapValues { .string($0) }
        if let exporter {
            let processor = BatchSpanProcessor(spanExporter: ObservedExporter(exporter, counters: deliveryCounters), scheduleDelay: 1,
                exportTimeout: 3, maxQueueSize: 256, maxExportBatchSize: 64)
            let provider = TracerProviderBuilder()
                .with(resource: Resource(attributes: [
                    "service.name": .string(serviceName),
                    "service.instance.id": .string(sessionID),
                    "deployment.environment": .string("development"),
                    "os.type": .string("darwin"),
                    "os.description": .string(ProcessInfo.processInfo.operatingSystemVersionString),
                    "logfire.integration": .string("swift-prototype"),
                ].merging(buildAttributes) { _, build in build }))
                .add(spanProcessor: processor).build()
            self.provider = provider
            tracer = provider.get(instrumentationName: "logfire.swift", instrumentationVersion: "0.1.0")
        } else {
            provider = nil
            tracer = DefaultTracer.instance
        }
    }

    public static func developmentEndpoint(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let raw = environment["LOGFIRE_DEV_ENDPOINT"], let url = URL(string: raw),
              url.scheme == "http", url.host == "127.0.0.1", url.path == "/v1/traces",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    /// The caller and Instruments observe the same operation interval.
    public func withSpan<T>(_ name: String, attributes: [String: AttributeValue] = [:], operation: () throws -> T) rethrows -> T {
        let span = begin(name, attributes: attributes)
        let interval = signposter.beginInterval("Operation", id: signposter.makeSignpostID(),
            "\(name, privacy: .public) session=\(self.sessionID, privacy: .public)")
        defer { signposter.endInterval("Operation", interval); span.end() }
        do { return try OpenTelemetry.instance.contextProvider.withActiveSpan(span, operation) }
        catch { span.status = .error(description: "Operation failed"); throw error }
    }

    public func event(_ name: String, attributes: [String: AttributeValue] = [:]) {
        let span = begin(name, attributes: attributes)
        span.end()
    }

    /// Window timestamps describe measurement time rather than upload time.
    public func window(_ name: String, started: Date, ended: Date, attributes: [String: AttributeValue]) {
        let span = begin(name, attributes: attributes, started: started)
        span.end(time: ended)
    }

    private func begin(_ name: String, attributes: [String: AttributeValue], started: Date = Date()) -> Span {
        let builder = tracer.spanBuilder(spanName: name).setStartTime(time: started)
        builder.setAttribute(key: "session_id", value: sessionID)
        builder.setAttribute(key: "logfire.msg", value: name)
        if let scenarioID { builder.setAttribute(key: "scenario.id", value: scenarioID) }
        for (key, value) in buildAttributes { builder.setAttribute(key: key, value: value) }
        for (key, value) in attributes { builder.setAttribute(key: key, value: value) }
        return builder.startSpan()
    }

    /// Call from a background queue when the application enters the background.
    public func flush() {
        provider?.forceFlush(timeout: 3)
#if canImport(MetricKit)
        if #available(macOS 27.0, iOS 27.0, *) { (appleReports as? MetricKitReports)?.flush() }
#endif
    }

    func startAppleMonitoring(serviceName: String, configuration: LogfireConfiguration?, options: AppleMonitoring) {
#if canImport(MetricKit)
        if #available(macOS 27.0, iOS 27.0, *), options.metricKit {
            let reports = MetricKitReports(serviceName: serviceName,
                exporter: configuration.map { ObservedExporter($0.makeExporter(), counters: deliveryCounters) },
                stateDomains: options.stateDomains, metadataKeys: options.metadataKeys)
            reports.startReports(enabled: true, stateDomains: options.stateDomains)
            appleReports = reports
        }
#endif
        lifecycle = AppleLifecycle { [weak self] in self?.flush() }
#if os(macOS)
        publishDevelopmentSession(directory: ProcessInfo.processInfo.environment["LOGFIRE_SESSION_DIR"] ?? ProcessInfo.processInfo.environment["NEON_OBSERVER_DIR"]
            ?? Self.developmentSessionsDirectory.path, stateDomains: options.stateDomains)
#endif
        if !buildAttributes.isEmpty { event("xcode.build.identity", attributes: ["measurement.source": .string("app.build_resource")]) }
    }

    public static func buildMetadata(bundle: Bundle) -> [String: String] {
        guard let url = bundle.url(forResource: "LogfireBuild", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        let allowed = Set(["build.id", "build.trace_id", "build.source_digest", "build.configuration",
                           "build.sdk", "git.commit", "xcode.version"])
        return values.filter { allowed.contains($0.key) }
    }

    /// The host observer verifies this marker against the running executable and process start time.
    public func publishDevelopmentSession(directory: String?, stateDomains: Set<String> = []) {
        guard let directory, let executable = Bundle.main.executableURL else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        var marker: [String: Any] = Self.buildMetadata(bundle: .main)
        marker["session_id"] = sessionID
        marker["pid"] = ProcessInfo.processInfo.processIdentifier
        marker["executable"] = executable.path
        marker["started_at"] = Date().timeIntervalSince1970
        marker["service.name"] = serviceName
        marker["state_domains"] = stateDomains.sorted()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
            let path = folder.appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json")
            try data.write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            signposter.emitEvent("Session", "session=\(self.sessionID, privacy: .public)")
        } catch { print("Development session marker unavailable") }
    }
}

public typealias LogfireAttribute = AttributeValue
