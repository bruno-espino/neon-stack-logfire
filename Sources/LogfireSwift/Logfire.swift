import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
import os

/// An experimental integration for local Apple development.
public final class Logfire {
    private let tracer: Tracer
    private let provider: TracerProviderSdk?
    public let metrics: DevelopmentMetrics?
    private let remoteParent: SpanContext?
    private var responsiveness: MainThreadMonitor?
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

    public convenience init(serviceName: String, configuration: LogfireConfiguration? = nil, resourceAttributes: [String: LogfireAttribute] = [:]) {
        self.init(serviceName: serviceName, exporter: configuration?.makeExporter(), metricExporter: configuration?.makeMetricExporter(), resourceAttributes: resourceAttributes)
    }

    init(serviceName: String, exporter: SpanExporter?, metricExporter: MetricExporter? = nil,
         environment: [String: String] = ProcessInfo.processInfo.environment, resourceAttributes: [String: LogfireAttribute] = [:]) {
        remoteParent = Self.traceContext(environment["LOGFIRE_TRACE_PARENT"])
        self.serviceName = serviceName
        scenarioID = environment["LOGFIRE_SCENARIO_ID"]
        let suppliedSession: UUID?
        if case .string(let value) = resourceAttributes["session_id"] { suppliedSession = UUID(uuidString: value) }
        else { suppliedSession = nil }
        sessionID = suppliedSession?.uuidString ?? environment["LOGFIRE_SESSION_ID"]
            .flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
        buildAttributes = Self.buildMetadata(bundle: .main).mapValues { .string($0) }
        var suppliedResource = resourceAttributes
        suppliedResource["session_id"] = .string(sessionID)
        let resource = Resource(attributes: [
            "service.name": .string(serviceName), "service.instance.id": .string(sessionID),
            "deployment.environment": .string("development"), "os.type": .string("darwin"),
            "os.description": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "logfire.integration": .string("swift-prototype"), "logfire.metric_schema.version": .string("1"), "session_id": .string(sessionID),
        ].merging(buildAttributes) { _, build in build }.merging(suppliedResource) { _, supplied in supplied })
        metrics = metricExporter.map { DevelopmentMetrics(exporter: $0, resource: resource) }
        if let exporter {
            let processor = BatchSpanProcessor(spanExporter: ObservedExporter(exporter, counters: deliveryCounters), scheduleDelay: 1,
                exportTimeout: 3, maxQueueSize: 256, maxExportBatchSize: 64)
            let provider = TracerProviderBuilder()
                .with(resource: resource)
                .add(spanProcessor: processor).build()
            self.provider = provider
            tracer = provider.get(instrumentationName: "logfire.swift", instrumentationVersion: "0.1.0")
        } else {
            provider = nil
            tracer = DefaultTracer.instance
        }
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
        let values = attributes.merging(["logfire.span_type": .string("log"), "logfire.level_num": .int(9)]) { supplied, _ in supplied }
        let span = begin(name, attributes: values)
        span.end()
    }

    public var activeTraceParent: String? {
        guard let context = OpenTelemetry.instance.contextProvider.activeSpan?.context, context.isValid else { return nil }
        return "00-\(context.traceId.hexString)-\(context.spanId.hexString)-\(context.traceFlags.hexString)"
    }

    static func traceContext(_ parent: String?) -> SpanContext? {
        guard let parent, parent.range(of: "^00-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}$", options: .regularExpression) != nil else { return nil }
        return W3CTraceContextPropagator().extract(carrier: ["traceparent": parent], getter: TraceParentGetter())
    }

    /// Window timestamps describe measurement time rather than upload time.
    public func window(_ name: String, started: Date, ended: Date, attributes: [String: AttributeValue], observations: () -> Void = {}) {
        var values = attributes
        values["measurement.started_at"] = .double(started.timeIntervalSince1970)
        values["measurement.ended_at"] = .double(ended.timeIntervalSince1970)
        values["logfire.span_type"] = .string("log")
        values["logfire.level_num"] = .int(9)
        let span = begin(name, attributes: values, started: ended)
        OpenTelemetry.instance.contextProvider.withActiveSpan(span, observations)
        span.end(time: ended)
    }

    private func begin(_ name: String, attributes: [String: AttributeValue], started: Date = Date()) -> Span {
        let builder = tracer.spanBuilder(spanName: name).setStartTime(time: started)
        if OpenTelemetry.instance.contextProvider.activeSpan?.context.isValid != true,
           let parent = remoteParent {
            builder.setParent(parent)
        }
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
        metrics?.flush()
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
        if options.responsiveness { responsiveness = MainThreadMonitor(client: self) }
        lifecycle = AppleLifecycle { [weak self] in self?.flush() }
#if os(macOS)
        publishDevelopmentSession(directory: ProcessInfo.processInfo.environment["LOGFIRE_SESSION_DIR"]
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
    private func publishDevelopmentSession(directory: String?, stateDomains: Set<String> = []) {
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

private struct TraceParentGetter: Getter {
    func get(carrier: [String: String], key: String) -> [String]? { carrier[key].map { [$0] } }
}
