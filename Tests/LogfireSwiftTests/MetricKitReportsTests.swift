#if canImport(MetricKit)
import Foundation
import MetricKit
import StateReporting
import XCTest
@testable import LogfireSwift

final class MetricKitReportsTests: XCTestCase {
    func testDiagnosticSummaryPreservesHistoricalTimeWithoutCurrentSession() throws {
        guard #available(macOS 27.0, iOS 27.0, *) else {
            throw XCTSkip("MetricKit Swift reports require macOS 27 or iOS 27")
        }
        let hang = try JSONDecoder().decode(HangDiagnostic.self, from: Data("""
            {"hangDuration":{"value":2500,"unit":"ms"},
             "callStackTree":{"callStackThreads":[],"callStackPerThread":true,"binaryInfo":[]}}
            """.utf8))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(DiagnosticResult.hang(hang))) as? [String: Any])
        let data = try JSONSerialization.data(withJSONObject: value.merging([
            "timeRange": ["begin": 0, "end": 2],
            "environment": ["regionFormat": "synthetic", "osVersion": ["platform": "macOS", "number": "27.0", "buildNumber": "synthetic"],
                "deviceType": "Test Mac", "platformArchitecture": "arm64", "lowPowerModeEnabled": false,
                "isTestFlightApp": false, "applicationVersion": "1.0", "applicationBuildVersion": "historical-12",
                "bundleIdentifier": "dev.test", "signpostData": [], "states": []]]) { _, report in report })
        let report = try JSONDecoder().decode(DiagnosticReport.self, from: data)
        let exporter = CaptureExporter()
        let bridge = MetricKitReports(serviceName: "diagnostic-test", exporter: exporter, stateDomains: [], metadataKeys: [])
        bridge.export(report); bridge.flush()
        let span = try XCTUnwrap(exporter.spans.first)
        XCTAssertEqual(span.name, "app.field.diagnostic")
        XCTAssertEqual(span.attributes["diagnostic.kind"], .string("hang"))
        XCTAssertEqual(span.attributes["diagnostic.duration_seconds"], .double(2.5))
        XCTAssertEqual(span.attributes["report.application_build_version"], .string("historical-12"))
        XCTAssertEqual(span.startTime, report.timeRange.start)
        XCTAssertEqual(span.endTime, report.timeRange.end)
        XCTAssertNil(span.attributes["session_id"])
        XCTAssertNil(span.resource.attributes["build.id"])
        XCTAssertEqual(span.status, .error(description: "Apple diagnostic"))
    }

    func testResourceMetricsNormalizeUnitsAndRetainHistogramBuckets() throws {
        guard #available(macOS 27.0, iOS 27.0, *) else {
            throw XCTSkip("MetricKit Swift reports require macOS 27 or iOS 27")
        }
        let cpu = try JSONDecoder().decode(CPUTimeMetric.self, from: Data("{\"value\":{\"value\":1500,\"unit\":\"ms\"}}".utf8))
        let gpu = try JSONDecoder().decode(GPUTimeMetric.self, from: Data("{\"value\":{\"value\":750,\"unit\":\"ms\"}}".utf8))
        let writes = try JSONDecoder().decode(LogicalDiskWritesMetric.self, from: Data("{\"value\":{\"value\":4096,\"unit\":\"B\"}}".utf8))
        let launch = try JSONDecoder().decode(TimeToFirstDrawMetric.self, from: Data("""
            {"histogram":{"buckets":[{"lowerBound":{"value":10,"unit":"ms"},
             "upperBound":{"value":20,"unit":"ms"},"count":2}]}}
            """.utf8))
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode([
            MetricResult.cpuTime(cpu), .gpuTime(gpu), .logicalDiskWrites(writes), .timeToFirstDraw(launch)]))
        let data = try JSONSerialization.data(withJSONObject: ["version": "2.0.0",
            "timeRange": ["begin": 0, "end": 86400], "intervalEntries": [
                ["states": [], "duration": ["value": 86400, "unit": "s"], "values": values]], "stateEntries": []])
        let report = try JSONDecoder().decode(MetricReport.self, from: data)
        let exporter = CaptureExporter()
        let bridge = MetricKitReports(serviceName: "field-test", exporter: exporter, stateDomains: [], metadataKeys: [])
        bridge.export(report); bridge.flush()
        XCTAssertEqual(exporter.spans.count, 4)
        XCTAssertEqual(exporter.spans.first { $0.name == "app.field.cpu_time" }?.attributes["cpu_seconds"], .double(1.5))
        XCTAssertEqual(exporter.spans.first { $0.name == "app.field.gpu_time" }?.attributes["gpu_seconds"], .double(0.75))
        XCTAssertEqual(exporter.spans.first { $0.name == "app.field.disk_writes" }?.attributes["disk_written_bytes"], .double(4096))
        let span = try XCTUnwrap(exporter.spans.first { $0.name == "app.field.launch_time" })
        XCTAssertEqual(span.attributes["histogram.count"], .int(2))
        guard case .string(let json) = span.attributes["histogram.buckets"] else { return XCTFail("Missing histogram") }
        let buckets = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Double]]
        XCTAssertEqual(buckets?.first?["lower_seconds"], 0.01)
        XCTAssertEqual(buckets?.first?["upper_seconds"], 0.02)
        XCTAssertEqual(buckets?.first?["count"], 2)
        XCTAssertTrue(exporter.spans.allSatisfy { $0.attributes["session_id"] == nil && $0.resource.attributes["build.id"] == nil })
    }

    func testHistoricalMetalReportsHaveNoCurrentSessionOrBuild() throws {
        guard #available(macOS 27.0, iOS 27.0, *) else {
            throw XCTSkip("MetricKit Swift reports require macOS 27 or iOS 27")
        }
        let metric = try JSONDecoder().decode(MetalFrameRateMetric.self, from: Data("""
            {"framesPerSecond":{"value":60,"unit":"Hz"},"frameCount":600,
             "activeDrawingDuration":{"value":10,"unit":"s"},"layerName":"Board"}
            """.utf8))
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MetricResult.metalFrameRate(metric)))
        let metadata = try JSONSerialization.jsonObject(with: JSONEncoder().encode([
            "auroraLayers": ReportableMetadataValue(48), "private": ReportableMetadataValue("synthetic-secret")]))
        let state: [String: Any] = ["domain": "test.rendering", "label": "aurora",
            "duration": ["value": 10, "unit": "s"], "stableMetadata": metadata]
        let data = try JSONSerialization.data(withJSONObject: [
            "version": "2.0.0", "timeRange": ["begin": 0, "end": 86400],
            "intervalEntries": [["states": [], "duration": ["value": 10, "unit": "s"], "values": [value]]],
            "stateEntries": [["state": state, "values": [value]],
                ["state": state.merging(["domain": "unselected"]) { _, new in new }, "values": [value]]],
        ])
        let report = try JSONDecoder().decode(MetricReport.self, from: data)
        let exporter = CaptureExporter()
        let bridge = MetricKitReports(serviceName: "field-test", exporter: exporter,
            stateDomains: ["test.rendering"], metadataKeys: ["auroraLayers"])
        bridge.export(report); bridge.flush()
        let spans = exporter.spans
        XCTAssertEqual(spans.count, 2)
        let daily = try XCTUnwrap(spans.first { $0.attributes["report.scope"] == .string("full-day") })
        let stateSpan = try XCTUnwrap(spans.first { $0.attributes["report.scope"] == .string("state") })
        XCTAssertEqual(daily.startTime, report.timeRange.start)
        XCTAssertEqual(daily.endTime, report.timeRange.end)
        XCTAssertEqual(daily.attributes["presented_fps"], .double(60))
        XCTAssertEqual(stateSpan.attributes["state.auroraLayers"], .int(48))
        XCTAssertEqual(stateSpan.attributes["state.label"], .string("aurora"))
        XCTAssertNil(stateSpan.attributes["state.private"])
        XCTAssertNil(daily.attributes["session_id"])
        XCTAssertNil(daily.attributes["build.id"])
        XCTAssertNil(daily.resource.attributes["build.id"])
        XCTAssertEqual(daily.attributes["report.id"], stateSpan.attributes["report.id"])
        bridge.export(report); bridge.flush()
        XCTAssertEqual(exporter.spans.last?.attributes["report.id"], daily.attributes["report.id"])
    }
}
#endif
