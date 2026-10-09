import Foundation
import XCTest
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp
@testable import LogfireSwift

private final class RequestCapture: HTTPClient {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    private func record(_ request: URLRequest) { lock.lock(); captured.append(request); lock.unlock() }
    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        record(request)
        completion(.success(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
    func send(request: URLRequest) async throws -> HTTPURLResponse {
        record(request)
        return HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }
}

final class ExportTests: XCTestCase {
    func testDeadlineCompletesOnceAndIgnoresLateResponses() throws {
        for status in [200, 503] {
            let started = expectation(description: "request starts")
            let completed = expectation(description: "deadline completes")
            let transport = DeferredTransport(onStart: { started.fulfill() })
            let client = DevelopmentHTTPClient(transport: transport)
            var request = URLRequest(url: URL(string: "https://example.test/v1/traces")!)
            request.timeoutInterval = 0.05
            DispatchQueue.global().async {
                client.send(request: request) { result in
                    if case .failure(let error) = result {
                        XCTAssertEqual((error as? URLError)?.code, .timedOut)
                    } else { XCTFail("A late response must not become an acknowledgement") }
                    completed.fulfill()
                }
            }
            wait(for: [started, completed], timeout: 1)
            transport.respond(status: status)
            let settled = expectation(description: "late callback settles")
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
            wait(for: [settled], timeout: 1)
            XCTAssertEqual(transport.requestCount, 1)
            XCTAssertEqual(client.delivery.failed, 1)
            XCTAssertEqual(client.delivery.retried, 0)
            XCTAssertEqual(client.delivery.lastFailure, "network_-1001")
        }
    }

    func testAsyncCancellationIgnoresLateFailureAndPreventsRetry() async throws {
        let started = expectation(description: "request starts")
        let transport = DeferredTransport(onStart: { started.fulfill() })
        let client = DevelopmentHTTPClient(transport: transport)
        var request = URLRequest(url: URL(string: "https://example.test/v1/traces")!)
        request.timeoutInterval = 3
        let task = Task { try await client.send(request: request) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        let completed = expectation(description: "cancellation completes")
        Task {
            do { _ = try await task.value; XCTFail("Cancellation must stop the request") }
            catch { XCTAssertTrue(error is CancellationError) }
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 0.5)
        transport.respond(status: 503)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(client.delivery.failed, 0)
        XCTAssertEqual(client.delivery.retried, 0)
    }

    func testDeadlineAndCancellationStopTheNativeURLSessionTask() async throws {
        for cancel in [false, true] {
            let started = expectation(description: "native request starts")
            let stopped = expectation(description: "native request stops")
            SlowURLProtocol.onStart = { started.fulfill() }
            SlowURLProtocol.onStop = { stopped.fulfill() }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SlowURLProtocol.self]
            let client = DevelopmentHTTPClient(transport: DevelopmentURLSession(configuration: configuration))
            var request = URLRequest(url: URL(string: "https://example.test/v1/traces")!)
            request.timeoutInterval = cancel ? 3 : 0.1
            let task = Task { try await client.send(request: request) }
            await fulfillment(of: [started], timeout: 1)
            if cancel { task.cancel() }
            do { _ = try await task.value; XCTFail("A stopped request must fail") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
            }
            await fulfillment(of: [stopped], timeout: 1)
            XCTAssertEqual(client.delivery.retried, 0)
            XCTAssertEqual(client.delivery.failed, cancel ? 0 : 1)
        }
        SlowURLProtocol.onStart = nil; SlowURLProtocol.onStop = nil
    }

    func testCancellationStopsAScheduledRetry() async throws {
        let started = expectation(description: "request starts")
        let transport = DeferredTransport(onStart: { started.fulfill() })
        let client = DevelopmentHTTPClient(transport: transport)
        var request = URLRequest(url: URL(string: "https://example.test/v1/traces")!)
        request.timeoutInterval = 3
        let task = Task { try await client.send(request: request) }
        await fulfillment(of: [started], timeout: 1)
        transport.respond(status: 503)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must stop the retry") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(client.delivery.failed, 1)
        XCTAssertEqual(client.delivery.retried, 0)
    }

    func testFlushDeliversAfterAConnectionLossWithoutAnotherEvent() throws {
        final class RecoveringTransport: HTTPClient {
            private let lock = NSLock()
            private var captured: [URLRequest] = []
            var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
            func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
                lock.lock()
                captured.append(request)
                let first = captured.count == 1
                lock.unlock()
                completion(first ? .failure(URLError(.networkConnectionLost)) :
                    .success(HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
            }
            func send(request: URLRequest) async throws -> HTTPURLResponse { throw URLError(.unsupportedURL) }
        }
        let configuration = try LogfireConfiguration(endpoint: XCTUnwrap(URL(string: "https://example.test/v1/traces")))
        let transport = RecoveringTransport()
        let client = Logfire(serviceName: "recovery-test", exporter: configuration.makeExporter(httpClient: transport))
        client.event("retained.event")
        client.flush()
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests.first?.httpBody, transport.requests.last?.httpBody)
        XCTAssertEqual(client.delivery.exportedSpans, 1)
        XCTAssertEqual(client.delivery.failedSpans, 0)
        XCTAssertEqual(client.delivery.attemptedBatches, 1)
        XCTAssertEqual(client.delivery.failedRequests, 1)
        XCTAssertEqual(client.delivery.retriedRequests, 1)
        XCTAssertEqual(client.delivery.lastFailure, "network_-1005")
    }

    func testOnlyOTLPRetryableHTTPStatusesAreRetried() throws {
        let configuration = try LogfireConfiguration(endpoint: XCTUnwrap(URL(string: "https://example.test/v1/traces")))
        let capture = CaptureExporter(), source = Logfire(serviceName: "source", exporter: capture)
        source.event("one"); source.flush()
        for status in [400, 401, 403, 404, 408, 429, 500, 501, 502, 503, 504] {
            let transport = StatusTransport(status: status)
            let exporter = configuration.makeExporter(httpClient: transport)
            let result = exporter.export(spans: capture.spans, explicitTimeout: 1)
            let retryable = [429, 502, 503, 504].contains(status)
            XCTAssertEqual(result, retryable ? .success : .failure, "HTTP \(status)")
            XCTAssertEqual(transport.requests.count, retryable ? 2 : 1, "HTTP \(status)")
            XCTAssertEqual(exporter.httpDelivery.failed, 1)
            XCTAssertEqual(exporter.httpDelivery.retried, retryable ? 1 : 0)
            if retryable {
                XCTAssertEqual(transport.requests.first?.httpBody, transport.requests.last?.httpBody)
                XCTAssertLessThan(transport.requests[1].timeoutInterval, transport.requests[0].timeoutInterval)
            }
        }
    }

    func testRetryAfterHonorsSecondsAndDatesWithoutExtendingTheBudget() throws {
        let configuration = try LogfireConfiguration(endpoint: XCTUnwrap(URL(string: "https://example.test/v1/traces")))
        let capture = CaptureExporter(), source = Logfire(serviceName: "source", exporter: capture)
        source.event("one"); source.flush()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for header in ["10", formatter.string(from: Date().addingTimeInterval(60))] {
            let transport = StatusTransport(status: 429, retryAfter: header)
            let exporter = configuration.makeExporter(httpClient: transport)
            let began = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(exporter.export(spans: capture.spans, explicitTimeout: 0.5), .failure)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 0.5)
            XCTAssertEqual(transport.requests.count, 1)
        }
        let transport = StatusTransport(status: 503, retryAfter: "0.25")
        let began = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(configuration.makeExporter(httpClient: transport).export(spans: capture.spans, explicitTimeout: 1), .success)
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - began, 0.25)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testASecondTemporaryFailureStopsAfterOneRetry() throws {
        let configuration = try LogfireConfiguration(endpoint: XCTUnwrap(URL(string: "https://example.test/v1/traces")))
        let transport = StatusTransport(status: 503, recovers: false)
        let client = Logfire(serviceName: "unavailable", exporter: configuration.makeExporter(httpClient: transport))
        client.event("one"); client.flush()
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(client.delivery.failedSpans, 1)
        XCTAssertEqual(client.delivery.exportedSpans, 0)
        XCTAssertEqual(client.delivery.failedRequests, 2)
        XCTAssertEqual(client.delivery.retriedRequests, 1)
        XCTAssertEqual(client.delivery.lastFailure, "http_503")
    }

    func testConfiguredTraceAndMetricRequestsUseGzipProtobuf() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.test/v1/traces"))
        let configuration = try LogfireConfiguration(endpoint: endpoint, token: "synthetic")
        let transport = RequestCapture(), rawTransport = RequestCapture(), spans = CaptureExporter()
        let client = Logfire(serviceName: "compression-test", exporter: spans,
            metricExporter: configuration.makeMetricExporter(httpClient: transport))
        for index in 0..<32 {
            client.event("compression.event", attributes: ["index": .int(index), "repeated": .string(String(repeating: "payload", count: 64))])
            client.metrics?.record(.frameInterval, value: Double(index + 1))
        }
        client.flush()
        XCTAssertEqual(configuration.makeExporter(httpClient: transport).export(spans: spans.spans, explicitTimeout: 3), .success)
        let raw = OtlpHttpTraceExporter(endpoint: endpoint, config: .init(compression: .none, exportAsJson: false),
            httpClient: rawTransport, envVarHeaders: [], requeueOnFailure: false)
        XCTAssertEqual(raw.export(spans: spans.spans, explicitTimeout: 3), .success)
        let trace = try XCTUnwrap(transport.requests.first { $0.url?.path == "/v1/traces" })
        XCTAssertLessThan(try XCTUnwrap(trace.httpBody).count, try XCTUnwrap(rawTransport.requests.first?.httpBody).count)
        XCTAssertTrue(transport.requests.contains { $0.url?.path == "/v1/metrics" })
        for request in transport.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Encoding"), "gzip")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-protobuf")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertEqual(Array(try XCTUnwrap(request.httpBody).prefix(2)), [0x1f, 0x8b])
        }
    }
}

private final class SlowURLProtocol: URLProtocol {
    static var onStart: (() -> Void)?
    static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() { Self.onStop?() }
}

private final class DeferredTransport: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [(URLRequest, (Result<HTTPURLResponse, Error>) -> Void)] = []
    private let onStart: () -> Void
    init(onStart: @escaping () -> Void) { self.onStart = onStart }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }
    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        lock.lock(); pending.append((request, completion)); let first = pending.count == 1; lock.unlock()
        if first { onStart() }
    }
    func respond(status: Int) {
        lock.lock(); let callbacks = pending; lock.unlock()
        for (request, completion) in callbacks {
            completion(.success(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!))
        }
    }
    func send(request: URLRequest) async throws -> HTTPURLResponse { throw URLError(.unsupportedURL) }
}

private final class StatusTransport: HTTPClient {
    private let lock = NSLock()
    private var captured: [URLRequest] = []
    private let status: Int
    private let retryAfter: String?
    private let recovers: Bool
    init(status: Int, retryAfter: String? = nil, recovers: Bool = true) {
        self.status = status; self.retryAfter = retryAfter; self.recovers = recovers
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        lock.lock(); captured.append(request); let first = captured.count == 1; lock.unlock()
        completion(.success(HTTPURLResponse(url: request.url!, statusCode: first || !recovers ? status : 200,
            httpVersion: nil, headerFields: retryAfter.map { ["Retry-After": $0] })!))
    }
    func send(request: URLRequest) async throws -> HTTPURLResponse { throw URLError(.unsupportedURL) }
}
