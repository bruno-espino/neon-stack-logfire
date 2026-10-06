import Foundation
import OpenTelemetryApi
import OpenTelemetrySdk

/// Fixed instruments keep diagnostic functions and capture IDs out of metric dimensions.
public enum DevelopmentMetric: String, CaseIterable {
    case frameInterval = "game.frame.interval"
    case preparation = "game.renderer.preparation"
    case gpuCommands = "game.gpu.commands.duration"
    case frames = "game.frame.count"
    case slowFrames = "game.frame.over_25ms.count"
    case callbackFPS = "game.render.callback_fps"
    case mainQueueDelay = "app.main_queue.delay"
    case mainQueuePending = "app.main_queue.pending_age.max"
    case mainThreadCPU = "app.main_thread.cpu.utilization"
    case processCPU = "app.process.cpu.utilization"
    case processMemory = "app.process.memory.footprint"
    case hostCPU = "apple.host.cpu.utilization"
    case hostMemory = "apple.host.memory.nonfree"
    case buildDuration = "apple.build.duration"
    case builds = "apple.build.count"

    var histogram: Bool { [.frameInterval, .preparation, .gpuCommands, .mainQueueDelay, .buildDuration].contains(self) }
    var counter: Bool { [.frames, .slowFrames, .builds].contains(self) }
    var unit: String {
        if histogram { return self == .buildDuration ? "s" : "ms" }
        if [.processMemory, .hostMemory].contains(self) { return "By" }
        if counter { return "{count}" }
        return self == .mainQueuePending ? "ms" : self == .callbackFPS ? "{frame}/s" : "1"
    }
}

public struct MetricDeliveryStatus {
    public let enabled: Bool
    public let exportedMetrics: Int
    public let failedMetrics: Int
}

public final class DevelopmentMetrics {
    private let provider: MeterProviderSdk
    private let exporter: ObservedMetricExporter
    private let histograms: [DevelopmentMetric: DoubleHistogramMeterSdk]
    private let gauges: [DevelopmentMetric: DoubleGaugeSdk]
    private let counters: [DevelopmentMetric: LongCounterSdk]
    public var delivery: MetricDeliveryStatus { exporter.delivery }

    init(exporter: MetricExporter, resource: Resource) {
        let observed = ObservedMetricExporter(exporter)
        self.exporter = observed
        let reader = PeriodicMetricReaderBuilder(exporter: observed).setInterval(timeInterval: 5).setExportTimeout(timeInterval: 4).build()
        provider = MeterProviderSdk.builder().setResource(resource: resource)
            .registerView(selector: InstrumentSelector.builder().setInstrument(name: ".*").build(),
                view: View.builder().withAggregation(aggregation: DefaultAggregation.instance).build())
            .registerMetricReader(reader: reader).build()
        let meter = provider.get(name: "logfire.swift.development")
        var histograms: [DevelopmentMetric: DoubleHistogramMeterSdk] = [:]
        var gauges: [DevelopmentMetric: DoubleGaugeSdk] = [:]
        var counters: [DevelopmentMetric: LongCounterSdk] = [:]
        for metric in DevelopmentMetric.allCases {
            if metric.histogram {
                let bounds: [Double] = metric == .buildDuration ? [0.1, 0.5, 1, 2, 5, 10, 20, 30, 60, 120, 300, 600] :
                    [0.01, 0.05, 0.1, 0.25, 0.5, 0.6, 0.75, 1, 2, 4, 8, 8.25, 8.333, 8.5, 10, 12, 15, 16, 16.25, 16.5, 16.667, 16.75, 17, 17.5, 18, 19, 20, 22, 24, 25, 27.5, 30, 33.333, 40, 50, 100, 250, 500, 1000, 1500, 2500, 5000, 10000]
                histograms[metric] = meter.histogramBuilder(name: metric.rawValue).setUnit(metric.unit)
                    .setExplicitBucketBoundariesAdvice(bounds).build()
            } else if metric.counter {
                counters[metric] = meter.counterBuilder(name: metric.rawValue).setUnit(metric.unit).build()
            } else { gauges[metric] = meter.gaugeBuilder(name: metric.rawValue).setUnit(metric.unit).build() }
        }
        self.histograms = histograms; self.gauges = gauges; self.counters = counters
    }

    /// Only fixed, short dimensions enter metrics. Build and process identity live on the resource.
    public func record(_ metric: DevelopmentMetric, value: Double, attributes: [String: LogfireAttribute] = [:]) {
        guard value.isFinite, value >= 0 else { return }
        let labels = attributes.filter { key, value in
            guard ["render_mode", "workload", "gpu_time.scope", "build.configuration", "build.cache_state", "outcome"].contains(key),
                  case .string(let text) = value else { return false }
            return !text.isEmpty && text.utf8.count <= 64
        }
        if let histogram = histograms[metric] { histogram.record(value: value, attributes: labels) }
        else if let gauge = gauges[metric] { gauge.record(value: value, attributes: labels) }
        else if let counter = counters[metric], value.rounded() == value, value < Double(Int.max) { counter.add(value: Int(value), attributes: labels) }
    }

    public func flush() { _ = provider.forceFlush() }
    deinit { _ = provider.shutdown() }
}

private final class ObservedMetricExporter: MetricExporter, @unchecked Sendable {
    private let wrapped: MetricExporter
    private let lock = NSLock()
    private var exported = 0
    private var failed = 0
    init(_ exporter: MetricExporter) { wrapped = exporter }
    var delivery: MetricDeliveryStatus {
        lock.lock(); defer { lock.unlock() }
        return .init(enabled: true, exportedMetrics: exported, failedMetrics: failed)
    }
    func export(metrics: [MetricData]) -> ExportResult {
        let result = wrapped.export(metrics: metrics)
        lock.lock()
        if result == .success { exported += metrics.count } else { failed += metrics.count }
        lock.unlock()
        return result
    }
    func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { wrapped.getAggregationTemporality(for: instrument) }
    func getDefaultAggregation(for instrument: InstrumentType) -> Aggregation { wrapped.getDefaultAggregation(for: instrument) }
    func flush() -> ExportResult { wrapped.flush() }
    func shutdown() -> ExportResult { wrapped.shutdown() }
}
