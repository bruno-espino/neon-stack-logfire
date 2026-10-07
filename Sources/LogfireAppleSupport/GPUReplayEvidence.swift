import Foundation

#if os(macOS)

    /// Selected replay nodes describe a captured workload. They do not measure live presentation or CPU waits.
    struct GPUReplayMeasurement: Codable {
        enum Scope: String, Codable {
            case encoder = "gpu_replay_encoder"
            case shader = "gpu_replay_shader"
        }
        enum Stage: String, Codable { case vertex, fragment, compute }
        let scope: Scope
        let nodeID: String
        let label: String
        let costFraction: Double
        let durationMilliseconds: Double?
        let stage: Stage?
        let instructions: Double?
        let waitInstructions: Double?
        let temporaryRegisters: Double?
        let uniformRegisters: Double?
        let spilledBytes: Double?

        enum CodingKeys: String, CodingKey {
            case scope = "measurement.scope"
            case nodeID = "gpu.node.id"
            case label = "gpu.node.label"
            case costFraction = "gpu.replay.cost_fraction"
            case durationMilliseconds = "gpu.replay.duration_ms"
            case stage = "gpu.shader.stage"
            case instructions = "gpu.instructions"
            case waitInstructions = "gpu.shader.wait_instructions"
            case temporaryRegisters = "gpu.shader.temp_registers"
            case uniformRegisters = "gpu.shader.uniform_registers"
            case spilledBytes = "gpu.shader.spilled_bytes"
        }

        var isValid: Bool {
            let pattern = scope == .encoder ? "^(re|ce|be)[0-9]+$" : "^(vert|frag|comp)[0-9]+$"
            let numbers = [
                durationMilliseconds, instructions, waitInstructions, temporaryRegisters, uniformRegisters,
                spilledBytes,
            ]
            return nodeID.range(of: pattern, options: .regularExpression) != nil && !label.isEmpty && label.count <= 512
                && costFraction.isFinite && (0...1).contains(costFraction)
                && numbers.compactMap { $0 }.allSatisfy { $0.isFinite && $0 >= 0 }
                && (scope == .encoder ? durationMilliseconds != nil : stage != nil)
        }
    }

    struct GPUReplayEvidence: Codable {
        let captureID: String
        let startedAt: String
        let endedAt: String
        let device: String
        let source: String
        let execution: String
        let state: String
        let selection: String
        let selectionLimit: Int
        let instrumented: Bool
        let measurements: [GPUReplayMeasurement]

        enum CodingKeys: String, CodingKey {
            case captureID = "capture.id"
            case startedAt = "capture.started_at"
            case endedAt = "capture.ended_at"
            case device = "gpu.device"
            case source = "measurement.source"
            case execution = "gpu.replay.exec"
            case state = "gpu.replay.state_requested"
            case selection = "gpu.selection"
            case selectionLimit = "gpu.selection_limit_per_scope"
            case instrumented = "profile.instrumented"
            case measurements = "gpu.measurements"
        }

        static func read(_ manifest: [String: Any], report: [String: Any]) throws -> GPUReplayEvidence {
            let evidence = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: manifest))
            guard UUID(uuidString: evidence.captureID) != nil,
                evidence.source == "apple.gpudebug", evidence.execution == "overlapping", evidence.state == "default",
                evidence.selection == "apple-cost-ranked-v1", evidence.selectionLimit == 3, evidence.instrumented,
                let start = NativeMeasurements.date(evidence.startedAt)?.timeIntervalSince1970,
                let end = NativeMeasurements.date(evidence.endedAt)?.timeIntervalSince1970,
                let runStart = SessionAnalysis.number(report["run.started_at"]),
                let duration = SessionAnalysis.number(report["app.duration_seconds"]),
                start >= runStart, end >= start, end <= runStart + duration + 1,
                evidence.measurements.count <= 6, evidence.measurements.allSatisfy(\.isValid),
                Set(evidence.measurements.map(\.nodeID)).count == evidence.measurements.count,
                evidence.measurements.filter({ $0.scope == .encoder }).count <= 3,
                evidence.measurements.filter({ $0.scope == .shader }).count <= 3
            else {
                throw CompanionError.message(
                    "GPU replay evidence has invalid scope, interval, or selected measurements")
            }
            return evidence
        }
    }
#endif
