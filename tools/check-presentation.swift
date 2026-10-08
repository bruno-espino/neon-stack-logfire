import Foundation

enum VerificationError: Error, CustomStringConvertible {
    case reportCount, incompleteScenario, missingPresentation, wrongDiagnosis
    var description: String {
        switch self {
        case .reportCount: return "Expected one retained scenario report in each directory."
        case .incompleteScenario: return "A scenario or its build identity is incomplete."
        case .missingPresentation: return "The reports lack full windows with confirmed presentation cadence."
        case .wrongDiagnosis:
            return
                "Measured cadence or diagnostic findings do not match the controlled policies. Inspect both retained reports."
        }
    }
}

struct PresentationResult: Encodable {
    let session: String
    let build: String
    let callbackHz: Double
    let presentedFPS: Double
    let frames: Int
    let presentations: Int
    let findingIDs: [String]
}

func result(in folder: URL) throws -> PresentationResult {
    let manager = FileManager.default
    let reports = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .map { $0.appendingPathComponent("report.json") }.filter { manager.fileExists(atPath: $0.path) }
    guard reports.count == 1 else { throw VerificationError.reportCount }
    guard let report = try JSONSerialization.jsonObject(with: Data(contentsOf: reports[0])) as? [String: Any],
        report["status"] as? String == "passed", let session = report["session_id"] as? String,
        let build = report["build.id"] as? String, let diagnostic = report["diagnostic"] as? [String: Any],
        let findings = diagnostic["findings"] as? [[String: Any]]
    else { throw VerificationError.incompleteScenario }
    let framesFile = reports[0].deletingLastPathComponent().appendingPathComponent("performance.jsonl")
    let windows = try String(contentsOf: framesFile, encoding: .utf8).split(separator: "\n").map {
        guard let row = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else {
            throw VerificationError.missingPresentation
        }
        return row
    }
    let complete = windows.filter { $0["window.partial"] as? Bool == false }
    var callbackSamples = 0.0
    var callbackSeconds = 0.0
    var intervals = 0.0
    var presentationSeconds = 0.0
    for window in complete {
        guard let frames = window["frames"] as? Double, frames > 0,
            let callback = window["render_callback_fps"] as? Double, callback > 0,
            let count = window["display_presentation_intervals"] as? Double, count > 0,
            let presented = window["display_presented_fps"] as? Double, presented > 0
        else {
            throw VerificationError.missingPresentation
        }
        callbackSamples += frames
        callbackSeconds += frames / callback
        intervals += count
        presentationSeconds += count / presented
    }
    guard !complete.isEmpty, callbackSeconds > 0, presentationSeconds > 0 else {
        throw VerificationError.missingPresentation
    }
    return PresentationResult(
        session: session, build: build, callbackHz: callbackSamples / callbackSeconds,
        presentedFPS: intervals / presentationSeconds,
        frames: windows.compactMap { $0["frames"] as? Int }.reduce(0, +),
        presentations: windows.compactMap { $0["display_presented_frames"] as? Int }.reduce(0, +),
        findingIDs: findings.compactMap { $0["id"] as? String })
}

do {
    guard CommandLine.arguments.count == 3 else { throw VerificationError.reportCount }
    let normal = try result(in: URL(fileURLWithPath: CommandLine.arguments[1]))
    let half = try result(in: URL(fileURLWithPath: CommandLine.arguments[2]))
    let normalRatio = normal.presentedFPS / normal.callbackHz
    let halfRatio = half.presentedFPS / half.callbackHz
    guard normal.build == half.build, normal.session != half.session,
        normalRatio >= 0.8, halfRatio >= 0.35, halfRatio <= 0.65,
        !normal.findingIDs.contains("presentation_cadence_gap"), half.findingIDs.contains("presentation_cadence_gap")
    else {
        throw VerificationError.wrongDiagnosis
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let file = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent(
        "verification.json")
    try encoder.encode(["normal": normal, "half-rate": half]).write(to: file, options: .atomic)
    print(
        String(
            format: "Normal: %.2f callbacks/s, %.2f presented FPS. Half-rate: %.2f callbacks/s, %.2f presented FPS.",
            normal.callbackHz, normal.presentedFPS, half.callbackHz, half.presentedFPS))
    print("Presentation diagnosis verified. This controlled submission policy is not a performance baseline.")
} catch {
    FileHandle.standardError.write(Data("Presentation verification incomplete: \(error)\n".utf8))
    exit(2)
}
