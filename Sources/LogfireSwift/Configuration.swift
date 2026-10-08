import Foundation
import OpenTelemetryProtocolExporterHttp
import OpenTelemetrySdk

public enum LogfireConfigurationError: Error, CustomStringConvertible {
    case missingCredentials, invalidEndpoint, invalidToken, unreadableCredentials

    public var description: String {
        switch self {
        case .missingCredentials: return "Direct development export requires LOGFIRE_TOKEN and LOGFIRE_BASE_URL."
        case .invalidEndpoint: return "Use an HTTPS ingest endpoint."
        case .invalidToken: return "The write token must be nonempty and contain no whitespace."
        case .unreadableCredentials: return "The development credential file is unavailable or invalid."
        }
    }
}

/// Runtime configuration for development and trusted tester builds.
public struct LogfireConfiguration: Sendable {
    public let endpoint: URL
    private let token: String?
    public static var developmentCredentialFile: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/logfire-swift/credentials.env")
    }

    public init(endpoint: URL, token: String? = nil) throws {
        guard endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil, endpoint.path == "/v1/traces",
              endpoint.scheme == "https"
        else { throw LogfireConfigurationError.invalidEndpoint }
        if let token, token.isEmpty || token.contains(where: { $0.isWhitespace || $0.isNewline }) {
            throw LogfireConfigurationError.invalidToken
        }
        self.endpoint = endpoint
        self.token = token
    }

    /// Direct export reads credentials only when the run explicitly enables it.
    public static func development(environment: [String: String] = ProcessInfo.processInfo.environment,
                                   credentialsFile: URL? = nil) throws -> LogfireConfiguration? {
        guard environment["LOGFIRE_DEV_DIRECT"] == "1" else { return nil }
        var values = environment
        if values["LOGFIRE_TOKEN"] == nil && values["LOGFIRE_BASE_URL"] == nil {
            let file = credentialsFile ?? environment["LOGFIRE_DEV_CREDENTIALS"].map { URL(fileURLWithPath: $0) } ?? developmentCredentialFile
            let data: Data
            do { data = try Data(contentsOf: file) }
            catch { throw LogfireConfigurationError.unreadableCredentials }
            guard data.count <= 65536, let text = String(data: data, encoding: .utf8) else {
                throw LogfireConfigurationError.unreadableCredentials
            }
            for line in text.components(separatedBy: .newlines) {
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2, ["LOGFIRE_TOKEN", "LOGFIRE_BASE_URL"].contains(String(parts[0])) {
                    values[String(parts[0])] = String(parts[1])
                }
            }
        }
        guard let token = values["LOGFIRE_TOKEN"], let base = values["LOGFIRE_BASE_URL"] else {
            throw LogfireConfigurationError.missingCredentials
        }
        guard let url = URL(string: base), url.path.isEmpty || url.path == "/" else {
            throw LogfireConfigurationError.invalidEndpoint
        }
        return try LogfireConfiguration(endpoint: url.appendingPathComponent("v1/traces"), token: token)
    }

    private var metricsEndpoint: URL { endpoint.deletingLastPathComponent().appendingPathComponent("metrics") }

    func makeMetricExporter(httpClient: HTTPClient = BaseHTTPClient()) -> OtlpHttpMetricExporter {
        OtlpHttpMetricExporter(endpoint: metricsEndpoint,
            config: .init(timeout: 3, compression: .gzip, exportAsJson: false),
            aggregationTemporalitySelector: AggregationTemporality.alwaysDelta(),
            httpClient: httpClient,
            envVarHeaders: token.map { [("Authorization", "Bearer " + $0)] } ?? [], requeueOnFailure: false)
    }

    func makeExporter(httpClient: HTTPClient = BaseHTTPClient()) -> OtlpHttpTraceExporter {
        OtlpHttpTraceExporter(endpoint: endpoint,
            config: .init(timeout: 3, compression: .gzip, exportAsJson: false),
            httpClient: httpClient,
            envVarHeaders: token.map { [("Authorization", "Bearer " + $0)] } ?? [], requeueOnFailure: false)
    }
}
