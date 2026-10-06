import Foundation

@main struct FlappyTests {
    static func main() {
        var idle = FlappyEngine(seed: 777)
        idle.advance(2)
        precondition(idle.y == 5 && !idle.gameOver, "The log must wait in place until the first flap")

        var falling = FlappyEngine(seed: 777)
        falling.flap()
        precondition(falling.velocity == FlappyEngine.flapVelocity && falling.flaps == 1)
        for _ in 0..<20 { falling.advance(0.1) }
        precondition(falling.gameOver && falling.score == 0, "A log that never flaps again must hit the ground")
        let crashed = falling
        falling.flap(); falling.advance(1)
        precondition(falling.flaps == crashed.flaps && falling.x == crashed.x, "A crashed log must stay still")

        var blocked = FlappyEngine(seed: 1)
        let column = blocked.columns[0]
        blocked.started = true
        blocked.x = column.x
        blocked.y = column.gapCenter + column.gapHalf + 0.5
        precondition(blocked.collides(), "Touching a fire column outside its gap must crash")
        blocked.y = column.gapCenter
        precondition(!blocked.collides(), "The center of a gap must be safe")

        var first = FlappyEngine(seed: 42), second = FlappyEngine(seed: 42)
        for _ in 0..<600 { first.advance(1.0 / 60, autoplay: true) }
        for _ in 0..<200 { second.advance(1.0 / 20, autoplay: true) }
        precondition(first.x == second.x && first.y == second.y && first.score == second.score,
                     "The same seed must replay identically regardless of frame rate")

        for seed: UInt64 in [1, 7, 42, 777, 9001] {
            var engine = FlappyEngine(seed: seed)
            var columns = engine.columns.map(\.gapCenter)
            for _ in 0..<(120 * 90) where !engine.gameOver {
                engine.advance(FlappyEngine.step, autoplay: true)
                columns += engine.columns.map(\.gapCenter)
            }
            precondition(!engine.gameOver && engine.score >= 50,
                         "Autopilot must survive a 90-second replay (seed \(seed), score \(engine.score))")
            precondition(engine.columns.count == 8, "The engine must keep eight columns ahead")
            precondition(columns.allSatisfy { $0 > 2 && $0 < 8 }, "Gaps must stay away from the floor and ceiling")
        }
        print("Flappy Log physics, collisions, determinism, and autopilot passed")
    }
}
