#if canImport(MetricKit) && (os(macOS) || os(iOS))
import CryptoKit
import Foundation
import MetricKit
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp

/// Export selected daily Metal measurements without attributing them to the current run.
@available(macOS 27.0, iOS 27.0, *)
public final class MetricKitReports {
    private let provider: TracerProviderSdk?
    private let tracer: Tracer
    private let domains: Set<String>
    private let metadataKeys: Set<String>
    private var task: Task<Void, Never>?

    public convenience init(serviceName: String, configuration: LogfireConfiguration?,
                            stateDomains: Set<String>, metadataKeys: Set<String> = []) {
        self.init(serviceName: serviceName, exporter: configuration?.makeExporter(),
                  stateDomains: stateDomains, metadataKeys: metadataKeys)
        startReports(enabled: configuration != nil, stateDomains: stateDomains)
    }

    public convenience init(serviceName: String, endpoint: URL?, stateDomains: Set<String>, metadataKeys: Set<String> = []) {
        let exporter = endpoint.map {
            OtlpHttpTraceExporter(endpoint: $0,
                config: .init(timeout: 3, compression: .none, exportAsJson: false),
                envVarHeaders: [], requeueOnFailure: false)
        }
        self.init(serviceName: serviceName, exporter: exporter, stateDomains: stateDomains, metadataKeys: metadataKeys)
        startReports(enabled: endpoint != nil, stateDomains: stateDomains)
    }

    private func startReports(enabled: Bool, stateDomains: Set<String>) {
        if enabled {
            let manager = MetricManager(enabledStateReportingDomains: Set(stateDomains.map { StateReportingDomain(rawValue: $0) }))
            task = Task { [weak self, manager] in
                for await report in manager.metricReports {
                    guard !Task.isCancelled else { break }
                    self?.export(report)
                }
            }
        }
    }

    init(serviceName: String, exporter: SpanExporter?, stateDomains: Set<String>, metadataKeys: Set<String>) {
        domains = stateDomains; self.metadataKeys = metadataKeys
        if let exporter {
            let provider = TracerProviderBuilder()
                .with(resource: Resource(attributes: ["service.name": .string(serviceName),
                    "deployment.environment": .string("development"),
                    "measurement.source": .string("apple.metrickit"),
                    "logfire.integration": .string("swift-prototype")]))
                .add(spanProcessor: BatchSpanProcessor(spanExporter: exporter, scheduleDelay: 1,
                    exportTimeout: 3, maxQueueSize: 256, maxExportBatchSize: 64)).build()
            self.provider = provider
            tracer = provider.get(instrumentationName: "logfire.swift.metrickit", instrumentationVersion: "0.1.0")
        } else { provider = nil; tracer = DefaultTracer.instance }
    }

    /// The report supplies the measurement dates and historical application version.
    public func export(_ report: MetricReport) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(report) else { return }
        var attributes: [String: AttributeValue] = [
            "report.id": .string(SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()),
            "report.delivered_at": .string(ISO8601DateFormatter().string(from: Date())),
            "measurement.source": .string("apple.metrickit"),
        ]
        if let environment = report.environment {
            attributes["report.application_build_version"] = .string(environment.applicationBuildVersion)
            attributes["report.includes_multiple_versions"] = .bool(environment.includesMultipleApplicationVersions)
            attributes["report.device_type"] = .string(environment.deviceType)
            attributes["report.low_power_mode"] = .bool(environment.lowPowerModeEnabled)
        }
        emit(report.intervalEntries.fullDayEntry.values, report: report,
             attributes: attributes.merging(["report.scope": .string("full-day")]) { _, value in value })
        for entry in report.stateEntries where domains.contains(entry.state.domain) {
            var stateAttributes = attributes
            stateAttributes["report.scope"] = .string("state")
            stateAttributes["state.domain"] = .string(entry.state.domain)
            stateAttributes["state.label"] = .string(entry.state.label)
            stateAttributes["state.duration_seconds"] = .double(entry.state.duration.converted(to: .seconds).value)
            for (key, value) in entry.state.stableMetadata where metadataKeys.contains(key) {
                switch value {
                case .string(let text): stateAttributes["state.\(key)"] = .string(text)
                case .integer(let number):
                    if let number = Int(exactly: number) { stateAttributes["state.\(key)"] = .int(number) }
                case .floatingPoint(let number): stateAttributes["state.\(key)"] = .double(number)
                case .date: break
                @unknown default: break
                }
            }
            emit(entry.values, report: report, attributes: stateAttributes)
        }
    }

    private func emit(_ values: [MetricResult], report: MetricReport, attributes: [String: AttributeValue]) {
        for value in values {
            guard case .metalFrameRate(let metric) = value else { continue }
            let builder = tracer.spanBuilder(spanName: "game.field.metal_frame_rate")
                .setStartTime(time: report.timeRange.start).setNoParent()
            for (key, value) in attributes { builder.setAttribute(key: key, value: value) }
            builder.setAttribute(key: "logfire.msg", value: "game.field.metal_frame_rate")
            builder.setAttribute(key: "presented_fps", value: metric.framesPerSecond.converted(to: .hertz).value)
            builder.setAttribute(key: "presented_frames", value: metric.frameCount)
            builder.setAttribute(key: "active_drawing_seconds", value: metric.activeDrawingDuration.converted(to: .seconds).value)
            builder.setAttribute(key: "layer_name", value: metric.layerName)
            builder.startSpan().end(time: report.timeRange.end)
        }
    }

    public func flush() { provider?.forceFlush(timeout: 3) }
    public func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
#endif
