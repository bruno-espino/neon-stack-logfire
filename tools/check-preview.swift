import Foundation

struct SpanDelivery: Decodable {
    let enabled: Bool
    let failed: Int
    enum CodingKeys: String, CodingKey {
        case enabled
        case failed = "failed_spans"
    }
}

struct MetricDelivery: Decodable {
    let enabled: Bool
    let failed: Int
    enum CodingKeys: String, CodingKey {
        case enabled
        case failed = "failed_metrics"
    }
}

struct Report: Decodable {
    let session: String
    let status: String
    let exitCode: Int
    let started: Double
    let duration: Double
    let appDelivery: SpanDelivery
    let appMetrics: MetricDelivery?
    let runnerDelivery: SpanDelivery
    let runnerMetrics: MetricDelivery?
    let issues: [String]
    enum CodingKeys: String, CodingKey {
        case session = "session_id"
        case status
        case exitCode = "exit_code"
        case started = "run.started_at"
        case duration = "run.duration_seconds"
        case appDelivery = "app.delivery"
        case appMetrics = "app.metric_delivery"
        case runnerDelivery = "runner.delivery"
        case runnerMetrics = "runner.metric_delivery"
        case issues
    }
}

struct Window: Decodable {
    let frames: Int
    let gpuSamples: Int
    let partial: Bool?
    let presented: Int?
    let intervals: Int?
    enum CodingKeys: String, CodingKey {
        case frames
        case gpuSamples = "gpu_samples"
        case partial = "window.partial"
        case presented = "display_presented_frames"
        case intervals = "display_presentation_intervals"
    }
}

struct SessionEvidence: Encodable {
    let label: String
    let sessionID: String
    let startedAt: String
    let endedAt: String
    let windows: Int
    let fullWindows: Int
    let frames: Int
    let gpuSamples: Int
    let presentedFrames: Int
    let presentationIntervals: Int
}

struct Verification: Encodable {
    let hostedReconciliationRequired: Bool
    let performanceBaseline = false
    let sessions: [SessionEvidence]
    let failures: [String]
}

guard CommandLine.arguments.count >= 3, let repetitions = Int(CommandLine.arguments[2]), (1...5).contains(repetitions)
else {
    fputs("Usage: swift tools/check-preview.swift DIRECTORY REPEAT [--no-telemetry]\n", stderr)
    exit(2)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let local = CommandLine.arguments.dropFirst(3).contains("--no-telemetry")
let manager = FileManager.default
let decoder = JSONDecoder()
let clock = ISO8601DateFormatter()
var sessions: [SessionEvidence] = []
var failures: [String] = []
let labels =
    (1...repetitions).flatMap { i in
        ["\(i)-normal", "\(i)-half-rate", "\(i)-bounded", "\(i)-every-frame", "\(i)-gpu-high"]
    } + ["continuous"]
let cases = try String(contentsOf: root.appendingPathComponent("cases.tsv"), encoding: .utf8).split(separator: "\n")
    .dropFirst()
var statuses: [String: String] = [:]
for line in cases {
    let fields = line.split(separator: "\t")
    guard fields.count == 2, statuses[String(fields[0])] == nil else {
        fputs("The case receipt contains a malformed or duplicate row.\n", stderr)
        exit(1)
    }
    statuses[String(fields[0])] = String(fields[1])
}
if Set(statuses.keys) != Set(labels) { failures.append("The case receipt does not match the requested matrix") }
for label in labels {
    let folder = root.appendingPathComponent(label, isDirectory: true)
    let enumerator = manager.enumerator(at: folder, includingPropertiesForKeys: nil)
    let reports =
        enumerator?.allObjects.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "report.json" } ?? []
    guard reports.count == 1, let reportURL = reports.first else {
        failures.append("\(label): expected exactly one scenario report")
        continue
    }
    do {
        let report = try decoder.decode(Report.self, from: Data(contentsOf: reportURL))
        guard statuses[label] == "0", report.exitCode == 0, report.status == "passed", report.issues.isEmpty else {
            failures.append("\(label): scenario or delivery is incomplete")
            continue
        }
        let spanDeliveries = [report.appDelivery, report.runnerDelivery]
        let metricDeliveries = [report.appMetrics, report.runnerMetrics]
        guard spanDeliveries.allSatisfy({ $0.failed == 0 && $0.enabled == !local }),
            metricDeliveries.allSatisfy({ delivery in
                guard let delivery else { return local }
                return delivery.failed == 0 && delivery.enabled == !local
            })
        else {
            failures.append("\(label): expected telemetry delivery state does not match")
            continue
        }
        let data = try Data(
            contentsOf: reportURL.deletingLastPathComponent().appendingPathComponent("performance.jsonl"))
        let windows = try data.split(separator: 10).filter { !$0.isEmpty }.map {
            try decoder.decode(Window.self, from: Data($0))
        }
        let full = windows.filter { $0.partial != true }
        guard full.count >= (label == "continuous" ? 9 : 1) else {
            failures.append("\(label): insufficient complete frame windows")
            continue
        }
        sessions.append(
            SessionEvidence(
                label: label, sessionID: report.session,
                startedAt: clock.string(from: Date(timeIntervalSince1970: report.started)),
                endedAt: clock.string(from: Date(timeIntervalSince1970: report.started + report.duration)),
                windows: windows.count, fullWindows: full.count,
                frames: windows.reduce(0) { $0 + $1.frames }, gpuSamples: windows.reduce(0) { $0 + $1.gpuSamples },
                presentedFrames: windows.reduce(0) { $0 + ($1.presented ?? 0) },
                presentationIntervals: windows.reduce(0) { $0 + ($1.intervals ?? 0) }))
    } catch { failures.append("\(label): invalid retained evidence: \(error)") }
}
if Set(sessions.map(\.sessionID)).count != sessions.count { failures.append("Session identities are duplicated") }
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
try encoder.encode(Verification(hostedReconciliationRequired: !local, sessions: sessions, failures: failures)).write(
    to: root.appendingPathComponent("verification.json"), options: .atomic)
for failure in failures { fputs(failure + "\n", stderr) }
guard failures.isEmpty, sessions.count == labels.count else { exit(1) }
print("Verified \(sessions.count) local sessions and \(sessions.reduce(0) { $0 + $1.frames }) frame samples.")
print(local ? "Exporters are disabled. Evidence remains local." : "Hosted reconciliation remains required.")
