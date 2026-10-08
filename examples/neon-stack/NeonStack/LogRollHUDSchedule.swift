import Foundation

/// The every-frame policy recreates the former SwiftUI publication bug only in a development scenario.
struct LogRollHUDSchedule {
    enum Policy: String { case bounded, everyFrame = "every-frame" }
    let policy: Policy
    private var lastMap = 0.0
    private(set) var hudPublications = 0
    private(set) var mapPublications = 0

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        policy = environment["LOGFIRE_SCENARIO_ID"] == LogRollScenario.id
            ? Policy(rawValue: environment["LOG_ROLL_HUD_POLICY"] ?? "") ?? .bounded : .bounded
    }

    mutating func refresh(changed: Bool, now: Double) -> (hud: Bool, map: Bool) {
        let hud = changed || policy == .everyFrame
        let map = changed || policy == .everyFrame || now - lastMap >= 1.0 / 30
        if hud { hudPublications += 1 }
        if map { lastMap = now; mapPublications += 1 }
        return (hud, map)
    }
}
