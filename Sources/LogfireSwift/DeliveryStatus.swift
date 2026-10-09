import Foundation
import OpenTelemetrySdk

public struct DeliveryStatus: Sendable {
    public let enabled: Bool
    public let exportedSpans: Int
    public let failedSpans: Int
    public let attemptedBatches: Int
    /// Failed trace HTTP attempts, including attempts that later recover through a retry.
    public let failedRequests: Int
    /// Additional trace HTTP attempts inside the original export timeout.
    public let retriedRequests: Int
    /// The most recent trace request failure code. It contains no URL, body, or credential.
    public let lastFailure: String?
}

final class DeliveryCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var exported = 0
    private var failed = 0
    private var batches = 0
    private var failedRequests = 0
    private var retriedRequests = 0
    private var lastFailure: String?

    func recordHTTP(failed: Int, retried: Int, lastFailure: String?) {
        lock.lock(); defer { lock.unlock() }
        failedRequests += failed; retriedRequests += retried
        if failed > 0 { self.lastFailure = lastFailure }
    }

    func record(count: Int, result: SpanExporterResultCode) {
        lock.lock(); defer { lock.unlock() }
        batches += 1
        if result == .success { exported += count } else { failed += count }
    }

    func snapshot(enabled: Bool) -> DeliveryStatus {
        lock.lock(); defer { lock.unlock() }
        return DeliveryStatus(enabled: enabled, exportedSpans: exported, failedSpans: failed, attemptedBatches: batches,
                              failedRequests: failedRequests, retriedRequests: retriedRequests, lastFailure: lastFailure)
    }
}

final class ObservedExporter: SpanExporter, @unchecked Sendable {
    private let exporter: SpanExporter
    private let counters: DeliveryCounters
    private let lock = NSLock()
    private var previousFailed = 0
    private var previousRetried = 0

    init(_ exporter: SpanExporter, counters: DeliveryCounters) { self.exporter = exporter; self.counters = counters }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        let result = exporter.export(spans: spans, explicitTimeout: explicitTimeout)
        counters.record(count: spans.count, result: result)
        if let transport = exporter as? DevelopmentTraceExporter {
            let status = transport.httpDelivery
            lock.lock(); defer { lock.unlock() }
            counters.recordHTTP(failed: max(0, status.failed - previousFailed), retried: max(0, status.retried - previousRetried),
                                lastFailure: status.lastFailure)
            previousFailed = max(previousFailed, status.failed); previousRetried = max(previousRetried, status.retried)
        }
        return result
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { exporter.flush(explicitTimeout: explicitTimeout) }
    func shutdown(explicitTimeout: TimeInterval?) { exporter.shutdown(explicitTimeout: explicitTimeout) }
}
