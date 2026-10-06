#if canImport(MetricKit)
import Foundation
import MetricKit
import StateReporting
import XCTest
@testable import LogfireSwift

@available(macOS 27.0, iOS 27.0, *)
final class MetricKitReportsTests: XCTestCase {
    func testHistoricalMetalReportsHaveNoCurrentSessionOrBuild() throws {
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
