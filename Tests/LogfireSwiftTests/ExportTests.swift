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
