import Foundation

@main struct LogRollTests {
    static func reachable(_ maze: Maze) -> Set<Int> {
        var seen: Set<Int> = [maze.index(maze.start.x, maze.start.z)], queue = [maze.start]
        while let (x, z) = queue.popLast() {
            for direction in Direction.allCases {
                let nx = x + direction.step.x, nz = z + direction.step.z
                if !maze.isWall(nx, nz) && seen.insert(maze.index(nx, nz)).inserted { queue.append((nx, nz)) }
            }
        }
        return seen
    }

    static func main() {
        for seed: UInt64 in 1...40 {
            var random = SeededRandom(state: seed)
            let maze = Maze(half: 4 + Int(seed % 8), jetDensity: 0.22, gateDensity: 0.25, random: &random)
            let open = Set((0..<(maze.size * maze.size)).filter { !maze.walls[$0] })
            precondition(reachable(maze) == open, "Every open cell must be reachable")
            precondition(open.contains(maze.index(maze.exit.x, maze.exit.z)), "The exit must be open")
            for index in 0..<maze.size where !maze.walls[index] || !maze.walls[maze.size * maze.size - 1 - index] {
                preconditionFailure("The border must be wall")
            }
            precondition(!maze.jets.isEmpty, "A dense maze must have fire")
            precondition(!maze.gates.isEmpty, "A maze must have gates")
            for gate in maze.gates {
                precondition(maze.jetAt[maze.index(gate.x, gate.z)] < 0, "Jets never sit on a gate")
                for facing in Direction.allCases {
                    precondition(maze.blocked(gate.x, gate.z, facing: facing) == (facing != gate.facing),
                                 "A gate opens only when its arrow points up the screen")
                }
            }
            for jet in maze.jets {
                precondition(!Direction.allCases.contains { maze.jetAt[maze.index(jet.x + $0.step.x, jet.z + $0.step.z)] >= 0 },
                             "No two jets may touch")
                precondition(abs(jet.x - 1) + abs(jet.z - 1) > 1, "The start and its neighbors stay cool")
            }
        }

        var idle = LogRollEngine(seed: 777)
        idle.advance(2)
        precondition(idle.position == (1, 1) && !idle.started && !idle.gameOver, "The log must wait at the start")

        var walker = LogRollEngine(seed: 777)
        let open = Direction.allCases.first { !walker.maze.isWall(1 + $0.step.x, 1 + $0.step.z) }!
        walker.press(open); walker.release(open)
        for _ in 0..<(LogRollEngine.moveSteps * 3) { _ = walker.tick() }
        precondition(walker.position == (Double(1 + open.step.x), Double(1 + open.step.z)) && walker.moves == 1,
                     "A tap must roll exactly one cell")
        var blocked = LogRollEngine(seed: 777)
        let wall = Direction.allCases.first { blocked.maze.isWall(1 + $0.step.x, 1 + $0.step.z) }!
        blocked.press(wall); blocked.advance(1)
        precondition(blocked.position == (1, 1) && blocked.moves == 0, "Walls must stop the log")

        var turner = LogRollEngine(seed: 777)
        turner.turn(1)
        for _ in 0..<(LogRollEngine.turnSteps - 1) { _ = turner.tick() }
        precondition(turner.facing == .up && turner.turning == 1, "A turn takes a moment")
        _ = turner.tick()
        precondition(turner.facing == .right && turner.turning == nil, "A turn ends a quarter around")
        precondition(turner.world(.up) == .right && turner.screen(.right) == .up, "Arrows follow the turned camera")

        let burned = LogRollEngine(seed: 5)
        let jet = burned.maze.jets[0]
        let safeClock = (0..<LogRollEngine.cycleTicks).first { !jet.burning($0) && jet.burning($0 + LogRollEngine.moveSteps) }!
        precondition(!burned.safe(from: (jet.x, jet.z), nil, at: safeClock), "Waiting on a jet as it ignites must burn")
        let ignition = (0..<LogRollEngine.cycleTicks).first { !jet.burning($0) && jet.burning($0 + 1) }!
        precondition(jet.warming(ignition) && !jet.warming(ignition + 1), "A jet must glow just before it ignites")

        var first = LogRollEngine(seed: 42), second = LogRollEngine(seed: 42)
        for _ in 0..<600 { first.advance(1.0 / 60, autoplay: true) }
        for _ in 0..<200 { second.advance(1.0 / 20, autoplay: true) }
        precondition(first.position == second.position && first.score == second.score && first.moves == second.moves,
                     "The same seed must replay identically regardless of frame rate")

        for seed: UInt64 in [1, 7, 42, 777, 9001] {
            var engine = LogRollEngine(seed: seed)
            precondition(engine.heat == 0 && !engine.water, "A new log starts fresh")
            for _ in 0..<(120 * 120) where !engine.gameOver { engine.advance(LogRollEngine.step, autoplay: true) }
            precondition(!engine.gameOver && engine.score > LogRollEngine.ablazeAt && engine.turns > 0,
                         "Autopilot must turn mazes and reach the water mazes (seed \(seed), score \(engine.score))")
            precondition(engine.heat == 1 && engine.water, "After enough mazes the log is ablaze")
        }
        for seed: UInt64 in [42, 777] {
            var engine = LogRollEngine(seed: seed), scenario = LogRollScenario()
            for _ in 0..<(30 * 60) where scenario.outcome == nil { scenario.advance(1.0 / 60, engine: &engine) }
            precondition(scenario.outcome == true && engine.score == 2 && engine.gameOver,
                         "Scenario must clear two mazes and lose through normal game rules (seed \(seed), \(scenario.failure))")
            print("Scenario seed \(seed) completes after \(engine.seconds) simulation seconds")
        }
        var crashed = LogRollEngine(seed: 777), rejected = LogRollScenario()
        crashed.gameOver = true
        rejected.advance(1.0 / 60, engine: &crashed)
        precondition(rejected.outcome == false, "An early crash must fail the scenario")
        print("Log Roll mazes, gates, fire, water, determinism, and autopilot passed")
    }
}
