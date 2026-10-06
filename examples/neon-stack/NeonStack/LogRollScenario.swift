import Foundation

/// This adapter uses ordinary game inputs and waits for the engine's loss condition.
struct LogRollScenario {
    static let id = "log-roll-two-mazes-then-loss-v1"
    private var accumulator = 0.0
    private var lossPlan: [LogRollEngine.Plan]?
    private var target: (x: Int, z: Int)?
    private var waiting = 0
    private(set) var outcome: Bool?
    private(set) var failure = ""

    @discardableResult mutating func advance(_ seconds: Double, engine: inout LogRollEngine) -> Int {
        guard outcome == nil else { return 0 }
        accumulator += min(seconds, 0.25)
        var cleared = 0
        while accumulator >= LogRollEngine.step, outcome == nil {
            accumulator -= LogRollEngine.step
            if engine.score < 2 { engine.autoplay() }
            else if engine.moving == nil, engine.turning == nil {
                if lossPlan == nil {
                    for jet in engine.maze.jets {
                        let goal = (x: jet.x, z: jet.z)
                        let route = engine.route(to: goal)
                        if !route.isEmpty { target = goal; lossPlan = route; break }
                    }
                    if lossPlan == nil { fail("No safe route to a loss grate."); break }
                }
                if waiting > 0 { waiting -= 1 }
                else if let action = lossPlan?.first {
                    lossPlan?.removeFirst()
                    switch action {
                    case .roll(let direction):
                        let screen = engine.screen(direction)
                        engine.press(screen); engine.release(screen)
                    case .turn(let direction): engine.turn(direction)
                    case .wait: waiting = LogRollEngine.moveSteps - 1
                    }
                }
            }
            cleared += engine.tick()
            if engine.score > 2 { fail("The loss route cleared another maze.") }
            else if engine.gameOver {
                if engine.score == 2, let target, engine.occupied == target { outcome = true }
                else { fail("The log crashed before the expected loss grate.") }
            }
        }
        return cleared
    }
    private mutating func fail(_ reason: String) { outcome = false; failure = reason }
}
