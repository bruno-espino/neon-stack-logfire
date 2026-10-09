import Foundation
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk

struct HTTPAttemptStatus: Sendable {
    let failed: Int
    let retried: Int
    let lastFailure: String?
}

private enum HTTPExportError: Error {
    case status(Int)
    case invalidResponse
}

/// Retries one eligible request within the exporter's original timeout. It retains no offline queue.
final class DevelopmentHTTPClient: HTTPClient, @unchecked Sendable {
    private let transport: HTTPClient
    private let lock = NSLock()
    private var failed = 0
    private var retried = 0
    private var lastFailure: String?

    init(transport: HTTPClient) { self.transport = transport }
    var delivery: HTTPAttemptStatus {
        lock.lock()
        defer { lock.unlock() }
        return .init(failed: failed, retried: retried, lastFailure: lastFailure)
    }

    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        let operation = operation(for: request)
        operation.start()
        // OTel waits after send returns. Complete here so its timeout cannot race a late callback.
        completion(operation.wait())
    }

    func send(request: URLRequest) async throws -> HTTPURLResponse {
        let operation = operation(for: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start { continuation.resume(with: $0) }
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private func operation(for request: URLRequest) -> HTTPRequestOperation {
        HTTPRequestOperation(
            request: request, transport: transport,
            recordFailure: { [self] label in
                lock.lock()
                failed += 1
                lastFailure = label
                lock.unlock()
            },
            recordRetry: { [self] in
                lock.lock()
                retried += 1
                lock.unlock()
            })
    }

    static func retryAfter(_ value: String?) -> Double? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}

private final class HTTPRequestOperation: @unchecked Sendable {
    typealias Response = Result<HTTPURLResponse, Error>
    private enum State {
        case idle, running
        case finished(Response)
    }
    private let condition = NSCondition()
    private var state = State.idle
    private var completion: ((Response) -> Void)?
    private var deadlineWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var task: URLSessionDataTask?
    private var requestActive = false
    private let request: URLRequest
    private let transport: HTTPClient
    private let deadline: Double
    private let recordFailure: @Sendable (String) -> Void
    private let recordRetry: @Sendable () -> Void

    init(
        request: URLRequest, transport: HTTPClient,
        recordFailure: @escaping @Sendable (String) -> Void, recordRetry: @escaping @Sendable () -> Void
    ) {
        self.request = request
        self.transport = transport
        self.deadline = ProcessInfo.processInfo.systemUptime + request.timeoutInterval
        self.recordFailure = recordFailure
        self.recordRetry = recordRetry
    }

    func start(completion: ((Response) -> Void)? = nil) {
        condition.lock()
        if case .finished(let result) = state {
            condition.unlock()
            completion?(result)
            return
        }
        guard case .idle = state else { preconditionFailure("An HTTP operation starts once") }
        state = .running
        self.completion = completion
        let work = DispatchWorkItem { [self] in finish(.failure(URLError(.timedOut)), expired: true) }
        deadlineWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
        condition.unlock()
        attempt(retry: true)
    }

    func wait() -> Response {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if case .finished(let result) = state { return result }
            condition.wait()
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Response, expired: Bool = false) {
        condition.lock()
        if case .finished = state {
            condition.unlock()
            return
        }
        if expired && requestActive { recordFailure("network_\(URLError.timedOut.rawValue)") }
        finishLocked(result)
    }

    /// The caller holds the condition. Release it before cancellation or user callbacks.
    private func finishLocked(_ result: Response) {
        state = .finished(result)
        let completion = completion
        let deadlineWork = deadlineWork
        let retryWork = retryWork
        let task = task
        self.completion = nil
        self.deadlineWork = nil
        self.retryWork = nil
        self.task = nil
        requestActive = false
        condition.broadcast()
        condition.unlock()
        deadlineWork?.cancel()
        retryWork?.cancel()
        task?.cancel()
        completion?(result)
    }

    private func attempt(retry: Bool) {
        condition.lock()
        guard case .running = state else {
            condition.unlock()
            return
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            finishLocked(.failure(URLError(.timedOut)))
            return
        }
        if !retry { recordRetry() }
        requestActive = true
        retryWork = nil
        var request = request
        request.timeoutInterval = remaining
        if let native = transport as? DevelopmentURLSession {
            let task = native.dataTask(request: request) { [self] in received($0, retry: retry) }
            self.task = task
            condition.unlock()
            task.resume()
        } else {
            condition.unlock()
            transport.send(request: request) { [self] in received($0, retry: retry) }
        }
    }

    private func received(_ result: Response, retry: Bool) {
        condition.lock()
        guard case .running = state else {
            condition.unlock()
            return
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            recordFailure("network_\(URLError.timedOut.rawValue)")
            finishLocked(.failure(URLError(.timedOut)))
            return
        }
        requestActive = false
        task = nil
        let failure: Error
        let eligible: Bool
        let serverDelay: Double
        let label: String
        switch result {
        case .success(let response) where (200..<300).contains(response.statusCode):
            finishLocked(.success(response))
            return
        case .success(let response):
            failure = HTTPExportError.status(response.statusCode)
            eligible = [429, 502, 503, 504].contains(response.statusCode)
            serverDelay = DevelopmentHTTPClient.retryAfter(response.value(forHTTPHeaderField: "Retry-After")) ?? 0
            label = "http_\(response.statusCode)"
        case .failure(let error):
            failure = error
            serverDelay = 0
            if let network = error as? URLError {
                eligible = [
                    .timedOut, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                    .dnsLookupFailed, .notConnectedToInternet,
                ].contains(network.code)
                label = "network_\(network.errorCode)"
            } else {
                eligible = false
                label = "transport_failure"
            }
        }
        recordFailure(label)
        let delay = max(serverDelay, Double.random(in: 0.1...0.2))
        guard retry, eligible, deadline - ProcessInfo.processInfo.systemUptime > delay else {
            finishLocked(.failure(failure))
            return
        }
        let work = DispatchWorkItem { [self] in attempt(retry: false) }
        retryWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
        condition.unlock()
    }
}

/// Preserve HTTP status codes for retry classification. Diagnostics never retain request URLs or bodies.
final class DevelopmentURLSession: HTTPClient, @unchecked Sendable {
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }
    func dataTask(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void)
        -> URLSessionDataTask
    {
        nonisolated(unsafe) let completion = completion
        return session.dataTask(with: request) { _, response, error in
            if let error {
                completion(.failure(error))
            } else if let response = response as? HTTPURLResponse {
                completion(.success(response))
            } else {
                completion(.failure(HTTPExportError.invalidResponse))
            }
        }
    }
    func send(request: URLRequest, completion: @escaping (Result<HTTPURLResponse, Error>) -> Void) {
        dataTask(request: request, completion: completion).resume()
    }
    func send(request: URLRequest) async throws -> HTTPURLResponse {
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw HTTPExportError.invalidResponse }
        return response
    }
}

final class DevelopmentTraceExporter: SpanExporter, @unchecked Sendable {
    private let exporter: OtlpHttpTraceExporter
    private let transport: DevelopmentHTTPClient
    var httpDelivery: HTTPAttemptStatus { transport.delivery }
    init(endpoint: URL, headers: [(String, String)], transport: HTTPClient) {
        self.transport = DevelopmentHTTPClient(transport: transport)
        exporter = OtlpHttpTraceExporter(
            endpoint: endpoint,
            config: .init(timeout: 3, compression: .gzip, exportAsJson: false),
            httpClient: self.transport, envVarHeaders: headers, requeueOnFailure: false)
    }
    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        exporter.export(spans: spans, explicitTimeout: explicitTimeout)
    }
    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        exporter.flush(explicitTimeout: explicitTimeout)
    }
    func shutdown(explicitTimeout: TimeInterval?) { exporter.shutdown(explicitTimeout: explicitTimeout) }
}
