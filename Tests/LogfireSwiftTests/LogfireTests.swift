import Foundation
import XCTest
import OpenTelemetryApi
import OpenTelemetrySdk
@testable import LogfireSwift

final class CaptureExporter: SpanExporter, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SpanData] = []
    var spans: [SpanData] { lock.lock(); defer { lock.unlock() }; return values }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        lock.lock(); defer { lock.unlock() }; values += spans; return .success
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
    func shutdown(explicitTimeout: TimeInterval?) {}
}

final class LogfireTests: XCTestCase {
    func testAsyncOperationsRetainParentsAcrossActorHopsAndConcurrentChildren() async throws {
        actor Probe {
            func record(_ client: Logfire, index: Int) -> String? {
                client.event("actor.\(index)")
                return client.activeTraceParent
            }
        }
        let exporter = CaptureExporter(), probe = Probe()
        let client = Logfire(serviceName: "async-test", exporter: exporter)
        await client.withSpan("outer") {
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        await client.withSpan("child.\(index)") {
                            await Task.yield()
                            let parent = await probe.record(client, index: index)
                            XCTAssertEqual(parent, client.activeTraceParent)
                            client.withSpan("sync.\(index)") { client.event("sync.event.\(index)") }
                        }
                    }
                }
            }
        }
        XCTAssertNil(client.activeTraceParent)
        client.flush()
        let spans = exporter.spans
        let outer = try XCTUnwrap(spans.first { $0.name == "outer" })
        XCTAssertEqual(spans.count, 33)
        XCTAssertEqual(Set(spans.map(\.traceId)), [outer.traceId])
        for index in 0..<8 {
            let child = try XCTUnwrap(spans.first { $0.name == "child.\(index)" })
            let actor = try XCTUnwrap(spans.first { $0.name == "actor.\(index)" })
            let sync = try XCTUnwrap(spans.first { $0.name == "sync.\(index)" })
            let event = try XCTUnwrap(spans.first { $0.name == "sync.event.\(index)" })
            XCTAssertEqual(child.parentSpanId, outer.spanId)
            XCTAssertEqual(actor.parentSpanId, child.spanId)
            XCTAssertEqual(sync.parentSpanId, child.spanId)
            XCTAssertEqual(event.parentSpanId, sync.spanId)
        }
    }

    func testAsyncFailuresAndCancellationEndSpansAndRestoreContext() async throws {
        enum Failure: Error { case intentional }
        let exporter = CaptureExporter()
        let client = Logfire(serviceName: "async-test", exporter: exporter)
        do {
            try await client.withSpan("failure") { await Task.yield(); throw Failure.intentional }
            XCTFail("Expected the original error")
        } catch { XCTAssertTrue(error is Failure) }
        let cancelled = Task {
            try await client.withSpan("cancelled") { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(client.activeTraceParent)
        client.flush()
        XCTAssertEqual(exporter.spans.first { $0.name == "failure" }?.status, .error(description: "Operation failed"))
        XCTAssertEqual(exporter.spans.first { $0.name == "cancelled" }?.status, .error(description: "Operation cancelled"))
    }

    func testAsyncSpanKeepsTheExistingGlobalContextProvider() async {
        let exporter = CaptureExporter()
        let client = Logfire(serviceName: "async-test", exporter: exporter)
        let foreign = TracerProviderBuilder().build().get(instrumentationName: "foreign").spanBuilder(spanName: "foreign").startSpan()
        OpenTelemetry.instance.contextProvider.withActiveSpan(foreign) {
            client.withSpan("before") { XCTAssertNotNil(OpenTelemetry.instance.contextProvider.activeSpan) }
        }
        await client.withSpan("async") { await Task.yield() }
        OpenTelemetry.instance.contextProvider.withActiveSpan(foreign) {
            client.withSpan("after") { XCTAssertNotNil(OpenTelemetry.instance.contextProvider.activeSpan) }
        }
        foreign.end(); client.flush()
        XCTAssertEqual(exporter.spans.first { $0.name == "before" }?.parentSpanId, foreign.context.spanId)
        XCTAssertEqual(exporter.spans.first { $0.name == "after" }?.parentSpanId, foreign.context.spanId)
    }
    func testBorrowedSessionIdentityMatchesChildSpansAndResourceAndRejectsInvalidOverrides() throws {
        let session = UUID().uuidString, environmentSession = UUID().uuidString
        for (value, expected) in [(session.lowercased(), session), ("invalid-session", environmentSession)] {
            let exporter = CaptureExporter()
            let client = Logfire(serviceName: "companion", exporter: exporter, environment: ["LOGFIRE_SESSION_ID": environmentSession],
                resourceAttributes: ["session_id": .string(value)])
            client.withSpan("run") { client.withSpan("cpu.analysis") { client.event("caller.path") } }
            client.flush()
            XCTAssertEqual(client.sessionID, expected)
            XCTAssertEqual(exporter.spans.count, 3)
            for span in exporter.spans {
                XCTAssertEqual(span.attributes["session_id"], .string(expected))
                XCTAssertEqual(span.resource.attributes["session_id"], .string(expected))
                XCTAssertEqual(span.resource.attributes["service.instance.id"], .string(expected))
            }
            XCTAssertEqual(Set(exporter.spans.map(\.traceId)).count, 1)
        }
    }
    func testDeliveryCountersExposeFailuresWithoutChangingOperations() {
        final class FailedExporter: SpanExporter, @unchecked Sendable {
            func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .failure }
            func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode { .success }
            func shutdown(explicitTimeout: TimeInterval?) {}
        }
        let client = Logfire(serviceName: "delivery-test", exporter: FailedExporter())
        XCTAssertEqual(client.withSpan("game-operation") { 42 }, 42)
        client.flush()
        XCTAssertTrue(client.delivery.enabled)
        XCTAssertEqual(client.delivery.failedSpans, 1)
        XCTAssertEqual(client.delivery.exportedSpans, 0)
        XCTAssertEqual(client.delivery.attemptedBatches, 1)
    }

    func testBuildMetadataExcludesUnrelatedBundleData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try JSONSerialization.data(withJSONObject: ["build.id": "build-42", "secret": "synthetic"])
        try data.write(to: directory.appendingPathComponent("LogfireBuild.json"))
        let bundle = try XCTUnwrap(Bundle(path: directory.path))
        XCTAssertEqual(Logfire.buildMetadata(bundle: bundle), ["build.id": "build-42"])
    }
    func testThrownOperationEndsAnErrorSpan() {
        enum Failure: Error { case intentional }
        let exporter = CaptureExporter()
        let client = Logfire(serviceName: "native-test", exporter: exporter)
        XCTAssertThrowsError(try client.withSpan("failure") { throw Failure.intentional })
        client.flush()
        XCTAssertEqual(exporter.spans.count, 1)
        XCTAssertEqual(exporter.spans.first?.status, .error(description: "Operation failed"))
    }

    func testNestedOperationsAndMeasurementTimestamps() {
        let exporter = CaptureExporter()
        let client = Logfire(serviceName: "native-test", exporter: exporter)
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        client.withSpan("outer") { client.event("inner", attributes: ["lines": .int(4)]) }
        client.window("window", started: started, ended: started.addingTimeInterval(5), attributes: ["frames": .int(300)])
        client.flush()
        let spans = exporter.spans
        XCTAssertEqual(spans.count, 3)
        let outer = spans.first { $0.name == "outer" }!
        let inner = spans.first { $0.name == "inner" }!
        let window = spans.first { $0.name == "window" }!
        XCTAssertEqual(inner.traceId, outer.traceId)
        XCTAssertEqual(inner.parentSpanId, outer.spanId)
        XCTAssertEqual(window.startTime, started.addingTimeInterval(5))
        XCTAssertEqual(window.attributes["measurement.started_at"], .double(started.timeIntervalSince1970))
        XCTAssertEqual(window.attributes["logfire.span_type"], .string("log"))
        XCTAssertEqual(window.endTime, started.addingTimeInterval(5))
        XCTAssertEqual(window.attributes["frames"], .int(300))
        XCTAssertEqual(window.attributes["session_id"], .string(client.sessionID))
        XCTAssertEqual(window.resource.attributes["service.name"], .string("native-test"))
    }

    func testUnauthenticatedLoopbackIsNoLongerASupportedTransport() throws {
        XCTAssertThrowsError(try LogfireConfiguration(endpoint: XCTUnwrap(URL(string: "http://127.0.0.1:4318/v1/traces")))) { error in
            XCTAssertEqual(error as? LogfireConfigurationError, .invalidEndpoint)
        }
    }

    func testDirectExportRequiresRuntimeOptInAndCompleteCredentials() throws {
        let missingFile = URL(fileURLWithPath: "/unavailable-logfire-credentials")
        XCTAssertNil(try LogfireConfiguration.development(environment: [
            "LOGFIRE_TOKEN": "synthetic", "LOGFIRE_BASE_URL": "https://logfire-us.pydantic.dev",
        ], credentialsFile: missingFile))
        XCTAssertThrowsError(try LogfireConfiguration.development(environment: [
            "LOGFIRE_DEV_DIRECT": "1", "LOGFIRE_TOKEN": "synthetic",
        ], credentialsFile: missingFile)) { error in
            XCTAssertEqual(error as? LogfireConfigurationError, .missingCredentials)
        }
        let configuration = try XCTUnwrap(LogfireConfiguration.development(environment: [
            "LOGFIRE_DEV_DIRECT": "1", "LOGFIRE_TOKEN": "synthetic",
            "LOGFIRE_BASE_URL": "https://logfire-us.pydantic.dev/",
        ], credentialsFile: missingFile))
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://logfire-us.pydantic.dev/v1/traces")
    }

    func testPrivateFileConfiguresDirectExportAndRejectsUnsafeTransport() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try "# Development only\nLOGFIRE_TOKEN=synthetic\nLOGFIRE_BASE_URL=https://logfire-eu.pydantic.dev\n"
            .write(to: file, atomically: true, encoding: .utf8)
        let configuration = try XCTUnwrap(LogfireConfiguration.development(
            environment: ["LOGFIRE_DEV_DIRECT": "1"], credentialsFile: file))
        XCTAssertEqual(configuration.endpoint.host, "logfire-eu.pydantic.dev")
        for endpoint in ["http://remote.example/v1/traces", "http://127.0.0.1:4318/v1/traces",
                         "https://secret@remote.example/v1/traces", "https://remote.example/v1/traces?token=secret"] {
            XCTAssertThrowsError(try LogfireConfiguration(endpoint: XCTUnwrap(URL(string: endpoint)), token: "synthetic"))
        }
        XCTAssertThrowsError(try LogfireConfiguration(endpoint: configuration.endpoint, token: "synthetic\nsecret")) { error in
            XCTAssertEqual(String(describing: error), "The write token must be nonempty and contain no whitespace.")
        }
    }

}
