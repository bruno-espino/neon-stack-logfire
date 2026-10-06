import XCTest
import OpenTelemetrySdk
@testable import LogfireSwift

final class CaptureMetricExporter: MetricExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MetricData] = []
    var result: ExportResult = .success
    var metrics: [MetricData] { lock.lock(); defer { lock.unlock() }; return values }
    func export(metrics: [MetricData]) -> ExportResult { lock.lock(); defer { lock.unlock() }; values += metrics; return result }
    func getAggregationTemporality(for instrument: InstrumentType) -> AggregationTemporality { .delta }
    func flush() -> ExportResult { .success }
    func shutdown() -> ExportResult { .success }
}

final class MetricsTests: XCTestCase {
    func testRawFrameHistogramPreservesCountsAndDoesNotReplayOnFlush() throws {
        let exporter = CaptureMetricExporter()
        let spans = CaptureExporter()
        let client = Logfire(serviceName: "test", exporter: spans, metricExporter: exporter)
        let recorder = FrameRecorder(client: client, stateDomain: "test.metrics", spanName: "window", began: 0)
        let context = RenderContext(mode: "test", width: 42, height: 42, metadata: ["player": .string("private")])
        for (time, frame) in [(2.0, 10.0), (3, 30), (7, 20)] {
            recorder.record(frameMilliseconds: frame, preparationMilliseconds: 1, gpuMilliseconds: nil,
                context: context, attributes: ["score": .int(42)], uptime: time, wallTime: Date())
        }
        recorder.finish(); client.flush()
        let samples = exporter.metrics.filter { $0.name == DevelopmentMetric.frameInterval.rawValue }
            .flatMap { $0.data.points.compactMap { $0 as? HistogramPointData } }
        XCTAssertEqual(samples.reduce(UInt64(0)) { $0 + $1.count }, 3)
        XCTAssertEqual(samples.reduce(0) { $0 + $1.sum }, 60)
        XCTAssertTrue(samples.allSatisfy { Set($0.attributes.keys) == ["render_mode", "workload", "gpu_time.scope"] })
        let report = try XCTUnwrap(spans.spans.first { $0.name == "window" })
        let exemplars = samples.flatMap(\.exemplars)
        XCTAssertFalse(exemplars.isEmpty)
        XCTAssertTrue(exemplars.allSatisfy { $0.spanContext?.traceId == report.traceId })
        XCTAssertFalse(exporter.metrics.contains { $0.name == DevelopmentMetric.gpuCommands.rawValue })
        XCTAssertGreaterThan(client.metrics!.delivery.exportedMetrics, 0)
    }

    func testMetricFailureIsVisibleAndNeverFailsAnAppOperation() {
        let exporter = CaptureMetricExporter(); exporter.result = .failure
        let client = Logfire(serviceName: "test", exporter: CaptureExporter(), metricExporter: exporter)
        XCTAssertEqual(client.withSpan("work") { client.metrics?.record(.builds, value: 1); return 42 }, 42)
        client.flush()
        XCTAssertEqual(client.metrics?.delivery.failedMetrics, 1)
    }

    func testPendingProbeRemainsVisibleWithoutCompletedLatencySamples() throws {
        var window = ResponsivenessWindow()
        XCTAssertNil(window.sample(now: 0, mainCPU: 1, process: (3, 4096), pendingAge: 0))
        let report = try XCTUnwrap(window.sample(now: 5, mainCPU: 1, process: (3, 4096), pendingAge: 4900))
        XCTAssertEqual(report["main_queue.pending_age_ms"], .double(4900))
        XCTAssertEqual(report["main_queue.completed_probes"], .int(0))
        XCTAssertEqual(report["main_thread.cpu.utilization"], .double(0))
        XCTAssertNil(report["main_queue.delay_p95_ms"])
    }

    func testPendingPeakSurvivesProbeCompletionAndResetsNextWindow() throws {
        var window = ResponsivenessWindow()
        _ = window.sample(now: 0, mainCPU: 0, process: nil, pendingAge: 0)
        _ = window.sample(now: 2, mainCPU: 0, process: nil, pendingAge: 1000)
        let stalled = try XCTUnwrap(window.sample(now: 5, mainCPU: 0, process: nil, pendingAge: 0))
        XCTAssertEqual(stalled["main_queue.pending_age_max_ms"], .double(1000))
        let quiet = try XCTUnwrap(window.sample(now: 10, mainCPU: 0, process: nil, pendingAge: 0))
        XCTAssertEqual(quiet["main_queue.pending_age_max_ms"], .double(0))
    }

    func testThreadAndProcessCPUUseDifferentOneCoreRatios() throws {
        var window = ResponsivenessWindow()
        _ = window.sample(now: 0, mainCPU: 1, process: (3, 4096), pendingAge: 0)
        window.delays = [1, 2, 1000]
        let report = try XCTUnwrap(window.sample(now: 5, mainCPU: 2, process: (13, 8192), pendingAge: 0))
        XCTAssertEqual(report["main_thread.cpu.utilization"], .double(0.2))
        XCTAssertEqual(report["process.cpu.utilization"], .double(2))
        XCTAssertEqual(report["main_queue.delay_max_ms"], .double(1000))
    }

    func testRemoteRunParentGroupsAppReportsAndRejectsMalformedInput() throws {
        let exporter = CaptureExporter()
        let parent = "00-11111111111111111111111111111111-2222222222222222-01"
        let client = Logfire(serviceName: "app", exporter: exporter, environment: ["LOGFIRE_TRACE_PARENT": parent])
        client.withSpan("operation") { client.event("nested") }
        client.event("report"); client.flush()
        let operation = try XCTUnwrap(exporter.spans.first { $0.name == "operation" })
        let report = try XCTUnwrap(exporter.spans.first { $0.name == "report" })
        XCTAssertEqual(operation.traceId.hexString, "11111111111111111111111111111111")
        XCTAssertEqual(report.parentSpanId?.hexString, "2222222222222222")
        XCTAssertEqual(exporter.spans.first { $0.name == "nested" }?.parentSpanId, operation.spanId)
        XCTAssertEqual(report.attributes["logfire.span_type"], .string("log"))
        for invalid in ["gg-11111111111111111111111111111111-2222222222222222-01", "00-00000000000000000000000000000000-2222222222222222-01", "invalid"] {
            XCTAssertNil(Logfire.traceContext(invalid))
        }
    }
}
