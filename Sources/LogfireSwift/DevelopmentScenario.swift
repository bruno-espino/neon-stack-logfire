import Foundation

public enum DevelopmentScenarioError: Error { case notReady, reportTooLarge }

/// A development app supplies readiness and its own scenario assertions.
public final class DevelopmentScenario {
    private let client: Logfire
    private let id: String
    private let output: URL
    private let lock = NSLock()
    private var ready = false
    private var finished = false

    public var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }

    public init?(client: Logfire, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let id = environment["LOGFIRE_SCENARIO_ID"], !id.isEmpty, id.count <= 128,
              let path = environment["LOGFIRE_SCENARIO_STATUS"], path.hasPrefix("/"),
              let session = environment["LOGFIRE_SESSION_ID"], UUID(uuidString: session)?.uuidString == client.sessionID else { return nil }
        self.client = client; self.id = id; output = URL(fileURLWithPath: path)
    }

    public func markReady() throws {
        lock.lock(); defer { lock.unlock() }
        guard !ready, !finished else { return }
        try write(phase: "ready", isReady: true, details: [:])
        ready = true
        client.event("development.scenario.ready", attributes: ["scenario.id": .string(id)])
    }

    /// A completed renderer window supplies readiness and retained local evidence.
    public func record(_ window: FrameWindow) throws {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        do {
            let file = output.deletingLastPathComponent().appendingPathComponent("performance.jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: window.encodedReport())
        } catch { lock.unlock(); throw error }
        lock.unlock()
        try markReady()
    }

    /// The monitor retains these windows only for an explicitly identified development scenario.
    func recordResponsiveness(_ values: [String: LogfireAttribute], ended: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var report: [String: Any] = values.compactMapValues { value in
            switch value {
            case .string(let value): return value
            case .int(let value): return value
            case .double(let value): return value
            case .bool(let value): return value
            default: return nil
            }
        }
        report["schema_version"] = 1; report["session_id"] = client.sessionID
        report["pid"] = ProcessInfo.processInfo.processIdentifier
        report["recorded_at"] = ended.timeIntervalSince1970
        let file = output.deletingLastPathComponent().appendingPathComponent("responsiveness.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10])
        guard data.count <= 65536 else { throw DevelopmentScenarioError.reportTooLarge }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }

    /// Call on a background queue. Flush queued telemetry before the runner sees completion.
    public func finish(passed: Bool, details: [String: String] = [:]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        guard ready else { throw DevelopmentScenarioError.notReady }
        client.event("development.scenario.finished", attributes: ["scenario.id": .string(id), "scenario.passed": .bool(passed)])
        client.flush()
        try write(phase: passed ? "passed" : "failed", isReady: true, details: details)
        finished = true
    }

    private func write(phase: String, isReady: Bool, details: [String: String]) throws {
        let value: [String: Any] = ["schema_version": 1, "scenario_id": id, "session_id": client.sessionID,
            "pid": ProcessInfo.processInfo.processIdentifier, "ready": isReady, "phase": phase,
            "recorded_at": Date().timeIntervalSince1970, "details": details,
            "delivery": ["enabled": client.delivery.enabled, "exported_spans": client.delivery.exportedSpans, "failed_spans": client.delivery.failedSpans]]
        var report = value
        if let delivery = client.metrics?.delivery {
            report["metric_delivery"] = ["enabled": delivery.enabled, "exported_metrics": delivery.exportedMetrics, "failed_metrics": delivery.failedMetrics]
        }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        guard data.count <= 65536 else { throw DevelopmentScenarioError.reportTooLarge }
        try data.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}
