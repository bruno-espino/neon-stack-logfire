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
    private var diagnosticsTask: Task<Void, Never>?

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

    func startReports(enabled: Bool, stateDomains: Set<String>) {
        if enabled {
            let manager = MetricManager(enabledStateReportingDomains: Set(stateDomains.map { StateReportingDomain(rawValue: $0) }))
            task = Task { [weak self, manager] in
                for await report in manager.metricReports {
                    guard !Task.isCancelled else { break }
                    self?.export(report)
                }
            }
            diagnosticsTask = Task { [weak self, manager] in
                for await report in manager.diagnosticReports {
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
            var measurements: [String: AttributeValue] = [:]
            let name: String
            switch value {
            case .metalFrameRate(let metric):
                name = "game.field.metal_frame_rate"
                measurements = ["presented_fps": .double(metric.framesPerSecond.converted(to: .hertz).value),
                    "presented_frames": .int(metric.frameCount),
                    "active_drawing_seconds": .double(metric.activeDrawingDuration.converted(to: .seconds).value),
                    "layer_name": .string(metric.layerName)]
            case .cpuTime(let metric):
                name = "app.field.cpu_time"
                measurements["cpu_seconds"] = .double(metric.value.converted(to: .seconds).value)
            case .cpuInstructionsCount(let metric):
                name = "app.field.cpu_instructions"
                measurements["cpu_instructions"] = .int(metric.value)
            case .gpuTime(let metric):
                name = "app.field.gpu_time"
                measurements["gpu_seconds"] = .double(metric.value.converted(to: .seconds).value)
            case .logicalDiskWrites(let metric):
                name = "app.field.disk_writes"
                measurements["disk_written_bytes"] = .double(metric.value.converted(to: .bytes).value)
            case .hitchTime(let metric):
                name = "app.field.hitches"
                measurements["hitch_seconds"] = .double(metric.totalHitchTime.converted(to: .seconds).value)
                measurements["animation_seconds"] = .double(metric.totalAnimationTime.converted(to: .seconds).value)
            case .hangTime(let metric):
                name = "app.field.hang_time"; measurements = histogram(metric.histogram)
            case .timeToFirstDraw(let metric):
                name = "app.field.launch_time"; measurements = histogram(metric.histogram)
            case .applicationResumeTime(let metric):
                name = "app.field.resume_time"; measurements = histogram(metric.histogram)
#if os(iOS)
            case .peakMemory(let metric):
                name = "app.field.peak_memory"
                measurements["peak_memory_bytes"] = .double(metric.value.converted(to: .bytes).value)
#endif
            default: continue
            }
            let builder = tracer.spanBuilder(spanName: name)
                .setStartTime(time: report.timeRange.start).setNoParent()
            for (key, value) in attributes.merging(measurements, uniquingKeysWith: { _, measurement in measurement }) {
                builder.setAttribute(key: key, value: value)
            }
            builder.setAttribute(key: "logfire.msg", value: name)
            builder.startSpan().end(time: report.timeRange.end)
        }
    }

    private func histogram(_ histogram: Histogram<UnitDuration>) -> [String: AttributeValue] {
        let buckets = histogram.buckets.map { bucket in
            ["lower_seconds": bucket.lowerBound.converted(to: .seconds).value,
             "upper_seconds": bucket.upperBound.converted(to: .seconds).value, "count": Double(bucket.count)]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: buckets, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return [:] }
        return ["histogram.buckets": .string(json), "histogram.count": .int(histogram.buckets.reduce(0) { $0 + $1.count })]
    }

    /// Export selected diagnostic fields. Raw exception messages and stacks remain outside this prototype.
    public func export(_ report: DiagnosticReport) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let encoded = try? encoder.encode(report) else { return }
        let kind: String
        var attributes: [String: AttributeValue] = [:]
        switch report.result {
        case .crash(let diagnostic):
            kind = "crash"
            if let signal = diagnostic.signal { attributes["diagnostic.signal"] = .int(signal) }
            if let category = diagnostic.terminationCategory { attributes["diagnostic.category"] = .string(category.rawValue) }
        case .hang(let diagnostic):
            kind = "hang"; attributes["diagnostic.duration_seconds"] = .double(diagnostic.hangDuration.converted(to: .seconds).value)
        case .cpuException(let diagnostic):
            kind = "cpu_exception"; attributes["diagnostic.cpu_seconds"] = .double(diagnostic.totalCPUTime.converted(to: .seconds).value)
        case .diskWriteException: kind = "disk_write_exception"
        case .appLaunch: kind = "launch"
#if os(iOS)
        case .memoryException: kind = "memory_exception"
#endif
        default: return
        }
        attributes.merge([
            "report.id": .string(SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()),
            "report.application_build_version": .string(report.environment.applicationBuildVersion),
            "report.delivered_at": .string(ISO8601DateFormatter().string(from: Date())),
            "diagnostic.kind": .string(kind), "measurement.source": .string("apple.metrickit"),
        ]) { _, report in report }
        let builder = tracer.spanBuilder(spanName: "app.field.diagnostic").setNoParent().setStartTime(time: report.timeRange.start)
        for (key, value) in attributes { builder.setAttribute(key: key, value: value) }
        builder.setAttribute(key: "logfire.msg", value: "Apple diagnostic: " + kind)
        let span = builder.startSpan()
        span.status = .error(description: "Apple diagnostic")
        span.end(time: report.timeRange.end)
    }

    public func flush() { provider?.forceFlush(timeout: 3) }
    public func stop() { task?.cancel(); task = nil; diagnosticsTask?.cancel(); diagnosticsTask = nil }
    deinit { task?.cancel(); diagnosticsTask?.cancel() }
}
#endif
