import Foundation
import OpenTelemetrySdk

public struct DeliveryStatus: Sendable {
    public let enabled: Bool
    public let exportedSpans: Int
    public let failedSpans: Int
    public let attemptedBatches: Int
}

final class DeliveryCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var exported = 0
    private var failed = 0
    private var batches = 0

    func record(count: Int, result: SpanExporterResultCode) {
        lock.lock(); defer { lock.unlock() }
        batches += 1
        if result == .success { exported += count } else { failed += count }
    }

    func snapshot(enabled: Bool) -> DeliveryStatus {
        lock.lock(); defer { lock.unlock() }
        return DeliveryStatus(enabled: enabled, exportedSpans: exported, failedSpans: failed, attemptedBatches: batches)
    }
}

final class ObservedExporter: SpanExporter, @unchecked Sendable {
    private let exporter: SpanExporter
    private let counters: DeliveryCounters

    init(_ exporter: SpanExporter, counters: DeliveryCounters) { self.exporter = exporter; self.counters = counters }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        let result = exporter.export(spans: spans, explicitTimeout: explicitTimeout)
        counters.record(count: spans.count, result: result)
        return result
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { exporter.flush(explicitTimeout: explicitTimeout) }
    func shutdown(explicitTimeout: TimeInterval?) { exporter.shutdown(explicitTimeout: explicitTimeout) }
}
