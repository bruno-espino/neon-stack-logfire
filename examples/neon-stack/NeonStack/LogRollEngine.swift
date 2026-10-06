import Foundation

enum Direction: Int, CaseIterable {
    case up, right, down, left
    /// Grid step. Up moves away from the camera, toward smaller z.
    var step: (x: Int, z: Int) { [(0, -1), (1, 0), (0, 1), (-1, 0)][rawValue] }
}

/// A floor grate that bursts into flame on a shared rhythm. Jets differ only by phase.
struct FireJet: Equatable {
    var x: Int
    var z: Int
    var phase: Int

    func moment(_ clock: Int) -> Int { (clock + phase) % LogRollEngine.cycleTicks }
    func burning(_ clock: Int) -> Bool { moment(clock) < LogRollEngine.burnTicks }
    /// The grate glows red for a moment before it ignites.
    func warming(_ clock: Int) -> Bool { moment(clock) >= LogRollEngine.cycleTicks - LogRollEngine.warnTicks }
}

/// A gate in a corridor. It is open only while the maze is turned so that `facing` points up the screen.
struct Gate: Equatable {
    var x: Int
    var z: Int
    var facing: Direction
}

/// A square maze on a grid. Cell (x, z) is centered at world (x, 0, z). The border is always wall.
struct Maze: Equatable {
    var size: Int
    var walls: [Bool]
    var jets: [FireJet]
    /// The jet index at each cell, or -1.
    var jetAt: [Int]
    var gates: [Gate]
    /// The gate index at each cell, or -1.
    var gateAt: [Int]
    var start: (x: Int, z: Int) { (1, 1) }
    var exit: (x: Int, z: Int) { (size - 2, size - 2) }

    func index(_ x: Int, _ z: Int) -> Int { z * size + x }
    func isWall(_ x: Int, _ z: Int) -> Bool { x < 0 || z < 0 || x >= size || z >= size || walls[index(x, z)] }
    func isGate(_ x: Int, _ z: Int) -> Bool { !isWall(x, z) && gateAt[index(x, z)] >= 0 }
    /// Whether the log can't enter this cell while the maze faces `facing`.
    func blocked(_ x: Int, _ z: Int, facing: Direction) -> Bool {
        isWall(x, z) || (isGate(x, z) && gates[gateAt[index(x, z)]].facing != facing)
    }
    func burning(_ x: Int, _ z: Int, clock: Int) -> Bool {
        guard !isWall(x, z) else { return false }
        let jet = jetAt[index(x, z)]
        return jet >= 0 && jets[jet].burning(clock)
    }

    /// A random maze with `half` rooms per side. A few extra walls are knocked out so there is more than one way
    /// around a fire, and no two jets touch, so a log can always wait beside a jet until it goes out.
    /// Some corridors get gates, and jets never sit on a gate.
    init(half: Int, jetDensity: Double, gateDensity: Double, random: inout SeededRandom) {
        func next(_ count: Int) -> Int { Int(random.next() >> 33) % count }
        let size = half * 2 + 1
        var walls = Array(repeating: true, count: size * size)
        var stack = [(1, 1)]
        walls[size + 1] = false
        while let (x, z) = stack.last {
            let options = Direction.allCases.filter {
                let nx = x + $0.step.x * 2, nz = z + $0.step.z * 2
                return nx > 0 && nz > 0 && nx < size - 1 && nz < size - 1 && walls[nz * size + nx]
            }
            guard !options.isEmpty else { stack.removeLast(); continue }
            let direction = options[next(options.count)]
            walls[(z + direction.step.z) * size + x + direction.step.x] = false
            walls[(z + direction.step.z * 2) * size + x + direction.step.x * 2] = false
            stack.append((x + direction.step.x * 2, z + direction.step.z * 2))
        }
        for z in 1..<(size - 1) {
            for x in 1..<(size - 1) where walls[z * size + x] && (x + z) % 2 == 1 && next(100) < 9 {
                walls[z * size + x] = false
            }
        }
        let open = (0..<(size * size)).filter { !walls[$0] }
        func awayFromEnds(_ cell: Int) -> Bool {
            let x = cell % size, z = cell / size
            return abs(x - 1) + abs(z - 1) > 1 && abs(x - (size - 2)) + abs(z - (size - 2)) > 1
        }
        // Gates go in corridors between rooms, which are the open cells with one odd coordinate.
        var gates: [Gate] = []
        var gateAt = Array(repeating: -1, count: size * size)
        var corridors = open.filter { ($0 % size + $0 / size) % 2 == 1 && awayFromEnds($0) }
        let gateTarget = max(1, Int(Double(corridors.count) * gateDensity))
        while gates.count < gateTarget && !corridors.isEmpty {
            let cell = corridors.remove(at: next(corridors.count))
            gateAt[cell] = gates.count
            gates.append(Gate(x: cell % size, z: cell / size, facing: Direction(rawValue: next(4))!))
        }
        var jets: [FireJet] = []
        var jetAt = Array(repeating: -1, count: size * size)
        var candidates = open.filter { awayFromEnds($0) && gateAt[$0] < 0 }
        let target = Int(Double(open.count) * jetDensity)
        while jets.count < target && !candidates.isEmpty {
            let cell = candidates.remove(at: next(candidates.count))
            let x = cell % size, z = cell / size
            guard !Direction.allCases.contains(where: { jetAt[(z + $0.step.z) * size + x + $0.step.x] >= 0 }) else { continue }
            jetAt[cell] = jets.count
            jets.append(FireJet(x: x, z: z, phase: next(LogRollEngine.cycleTicks)))
        }
        self.size = size; self.walls = walls; self.jets = jets; self.jetAt = jetAt; self.gates = gates; self.gateAt = gateAt
    }

    static func == (a: Maze, b: Maze) -> Bool {
        a.size == b.size && a.walls == b.walls && a.jets == b.jets && a.gates == b.gates
    }
}

/// What the player (or autopilot) asked for next.
enum RollAction: Equatable {
    /// Roll one cell toward a screen direction.
    case roll(Direction)
    /// Turn the maze a quarter: +1 swings the camera clockwise, -1 counterclockwise.
    case turn(Int)
}

/// Log Roll rules. The log rolls one cell at a time through a 3D maze toward the exit.
/// Floor grates burst into flame on a fixed rhythm, and a log on a burning cell catches fire.
/// Gates only open when the maze is turned the right way. Every maze heats the log a little more,
/// and once it is fully ablaze the grates spray water instead, which puts the log out.
/// Each cleared maze is one point, and the next maze is bigger.
struct LogRollEngine {
    static let step = 1.0 / 120.0
    /// Ticks to roll one cell.
    static let moveSteps = 18
    /// Every jet burns for `burnTicks` out of every `cycleTicks`, a whole number of moves.
    static let cycleTicks = moveSteps * 16
    static let burnTicks = 110
    static let warnTicks = 60
    /// Ticks to turn the maze a quarter, two moves' worth.
    static let turnSteps = moveSteps * 2
    /// Mazes escaped before the log is fully on fire and the water mazes begin.
    static let ablazeAt = 4

    private(set) var maze: Maze
    private(set) var level = 0
    var score = 0
    var started = false
    var gameOver = false
    private(set) var moves = 0
    /// Ticks since this maze began. The fire rhythm follows it.
    private(set) var clock = 0
    private(set) var ticks = 0
    private(set) var x = 1
    private(set) var z = 1
    private(set) var moving: Direction?
    private(set) var moveTick = 0
    /// True when the log lies along x, which is how it rolls up and down the screen.
    private(set) var lyingAlongX = true
    /// How far the log has turned, in radians.
    private(set) var rolled = 0.0
    /// The world direction that points up the screen.
    private(set) var facing = Direction.up
    private(set) var turning: Int?
    private(set) var turnTick = 0
    private(set) var turns = 0
    private var held: Direction?
    private var queued: RollAction?
    private var plan: [Plan] = []
    private var waiting = 0
    private var random: SeededRandom
    private var accumulator = 0.0

    var seconds: Double { Double(ticks) * Self.step }
    /// How hot the log is, from 0 for fresh wood to 1 for fully ablaze.
    var heat: Double { min(Double(level) / Double(Self.ablazeAt), 1) }
    /// In water mazes the log is on fire and the grates spray water.
    var water: Bool { level >= Self.ablazeAt }
    /// The camera's turn in quarter turns, between whole numbers while the maze turns.
    var turnAngle: Double {
        Double(facing.rawValue) + Double(turning ?? 0) * Double(turnTick) / Double(Self.turnSteps)
    }
    /// Where the log is drawn, between cells while it rolls.
    var position: (x: Double, z: Double) {
        guard let moving else { return (Double(x), Double(z)) }
        let progress = Double(moveTick) / Double(Self.moveSteps)
        return (Double(x) + Double(moving.step.x) * progress, Double(z) + Double(moving.step.z) * progress)
    }
    /// The cell the log counts as standing on: the start cell for the first half of a roll, then the next one.
    var occupied: (x: Int, z: Int) {
        guard let moving, moveTick * 2 >= Self.moveSteps else { return (x, z) }
        return (x + moving.step.x, z + moving.step.z)
    }

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        random = SeededRandom(state: seed)
        maze = Self.maze(level: 0, random: &random)
    }

    private static func maze(level: Int, random: inout SeededRandom) -> Maze {
        Maze(half: min(4 + level, 11), jetDensity: min(0.1 + 0.025 * Double(level), 0.22),
             gateDensity: min(0.08 + 0.03 * Double(level), 0.25), random: &random)
    }

    private mutating func nextMaze() {
        level += 1
        maze = Self.maze(level: level, random: &random)
        (x, z) = maze.start
        clock = 0; plan = []; waiting = 0; queued = nil
    }

    /// Converts a direction on screen to a direction in the maze.
    func world(_ screen: Direction) -> Direction { Direction(rawValue: (screen.rawValue + facing.rawValue) % 4)! }
    func screen(_ world: Direction) -> Direction { Direction(rawValue: (world.rawValue - facing.rawValue + 4) % 4)! }

    /// An arrow went down. A tap rolls one cell, holding it keeps rolling.
    mutating func press(_ direction: Direction) {
        guard !gameOver else { return }
        held = direction; queued = .roll(direction)
    }
    mutating func release(_ direction: Direction) { if held == direction { held = nil } }
    /// Turns the maze a quarter. The log can't turn the maze while it sits in a gate.
    mutating func turn(_ direction: Int) {
        guard !gameOver else { return }
        queued = .turn(direction > 0 ? 1 : -1)
    }

    private mutating func begin(_ screen: Direction) -> Bool {
        let direction = world(screen)
        guard !maze.blocked(x + direction.step.x, z + direction.step.z, facing: facing) else { return false }
        started = true
        moving = direction; moveTick = 0; moves += 1
        lyingAlongX = direction.step.x == 0
        return true
    }

    /// Advances by real elapsed time. Returns the number of mazes cleared during this call.
    @discardableResult mutating func advance(_ seconds: Double, autoplay: Bool = false) -> Int {
        accumulator += min(seconds, 0.25)
        var cleared = 0
        while accumulator >= Self.step {
            accumulator -= Self.step
            if autoplay { self.autoplay() }
            cleared += tick()
        }
        return cleared
    }

    /// One fixed simulation step. Returns 1 when the log reaches the exit.
    mutating func tick() -> Int {
        guard !gameOver else { return 0 }
        if moving == nil && turning == nil, let action = queued ?? held.map(RollAction.roll) {
            queued = nil
            switch action {
            case .roll(let direction): _ = begin(direction)
            case .turn(let direction) where !maze.isGate(x, z):
                started = true
                turning = direction; turnTick = 0; turns += 1
            case .turn: break
            }
        }
        clock += 1
        if started { ticks += 1 }
        if let direction = turning {
            turnTick += 1
            if turnTick == Self.turnSteps {
                facing = Direction(rawValue: (facing.rawValue + direction + 4) % 4)!
                turning = nil
            }
        }
        if let direction = moving {
            moveTick += 1
            rolled += (direction == .up || direction == .left ? -1 : 1) / (Double(Self.moveSteps) * 0.3)
        }
        let cell = occupied
        if maze.burning(cell.x, cell.z, clock: clock) { gameOver = true; return 0 }
        guard let direction = moving, moveTick == Self.moveSteps else { return 0 }
        x += direction.step.x; z += direction.step.z
        moving = nil
        guard (x, z) == maze.exit else { return 0 }
        score += 1
        nextMaze()
        return 1
    }

    // MARK: Autopilot

    enum Plan: Equatable { case roll(Direction), wait, turn(Int) }

    /// Deterministic autopilot for benchmarks. It finds the quickest safe route to the exit once per maze,
    /// treating each step as one roll, one roll's worth of waiting, or a turn of the maze, then follows it exactly.
    mutating func autoplay() {
        guard moving == nil, turning == nil, !gameOver else { return }
        if waiting > 0 { waiting -= 1; return }
        if plan.isEmpty { plan = route() }
        guard !plan.isEmpty else { return }
        switch plan.removeFirst() {
        case .roll(let direction): queued = .roll(screen(direction))
        case .turn(let direction): queued = .turn(direction)
        case .wait: waiting = Self.moveSteps - 1
        }
    }

    /// Whether a roll from the log's cell (or a wait, when `direction` is nil) starting at `clock` stays out of the fire.
    func safe(from cell: (x: Int, z: Int), _ direction: Direction?, at clock: Int) -> Bool {
        let target = direction.map { (cell.x + $0.step.x, cell.z + $0.step.z) } ?? cell
        return (1...Self.moveSteps).allSatisfy { step in
            let spot = direction != nil && step * 2 >= Self.moveSteps ? target : cell
            return !maze.burning(spot.0, spot.1, clock: clock + step)
        }
    }

    /// Breadth-first search over (cell, which way the maze faces, moment in the fire rhythm). The rhythm repeats
    /// every 16 steps, so that is the whole state. A turn takes two steps, which keeps the search almost shortest-first.
    func route() -> [Plan] {
        let size = maze.size, layers = Self.cycleTicks / Self.moveSteps
        func state(_ cell: (x: Int, z: Int), _ facing: Int, _ layer: Int) -> Int {
            (maze.index(cell.x, cell.z) * 4 + facing) * layers + layer % layers
        }
        let start = state((x, z), facing.rawValue, 0)
        var parent = Array(repeating: -1, count: size * size * 4 * layers)
        var action = Array(repeating: Plan.wait, count: parent.count)
        parent[start] = start
        var queue = [start], head = 0
        while head < queue.count {
            let current = queue[head]; head += 1
            let layer = current % layers, facing = current / layers % 4, cell = current / layers / 4
            let here = (x: cell % size, z: cell / size)
            if here == maze.exit && current != start {
                var path: [Plan] = []
                var walk = current
                while walk != start { path.append(action[walk]); walk = parent[walk] }
                return path.reversed()
            }
            let time = clock + layer * Self.moveSteps
            var options: [(Plan, Int)] = []
            if safe(from: here, nil, at: time) {
                options.append((.wait, state(here, facing, layer + 1)))
                if !maze.isGate(here.x, here.z) && safe(from: here, nil, at: time + Self.moveSteps) {
                    for turn in [1, -1] { options.append((.turn(turn), state(here, (facing + turn + 4) % 4, layer + 2))) }
                }
            }
            for direction in Direction.allCases {
                let next = (x: here.x + direction.step.x, z: here.z + direction.step.z)
                guard !maze.blocked(next.x, next.z, facing: Direction(rawValue: facing)!),
                      safe(from: here, direction, at: time) else { continue }
                options.append((.roll(direction), state(next, facing, layer + 1)))
            }
            for (plan, following) in options where parent[following] < 0 {
                parent[following] = current; action[following] = plan
                queue.append(following)
            }
        }
        return []
    }
}
