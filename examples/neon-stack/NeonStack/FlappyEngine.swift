import Foundation

struct FireColumn: Equatable {
    var index: Int
    var x: Double
    var gapCenter: Double
    var gapHalf: Double
}

/// Flappy Log rules. The world is 10 units tall. The log flies toward +x and the camera follows it.
/// The simulation uses a fixed step so a seed and a list of flap times always replay identically.
struct FlappyEngine {
    static let worldHeight = 10.0
    static let step = 1.0 / 120.0
    static let gravity = -26.0
    static let flapVelocity = 8.6
    static let columnSpacing = 6.0
    static let columnHalfWidth = 0.7
    static let logHalfLength = 0.75
    static let logRadius = 0.32
    static let firstColumnX = 12.0

    var x = 0.0
    var y = 5.0
    var velocity = 0.0
    var time = 0.0
    var score = 0
    var started = false
    var gameOver = false
    var flaps = 0
    private(set) var steps = 0
    private(set) var columns: [FireColumn] = []
    private var random: SeededRandom
    private var accumulator = 0.0

    var speed: Double { min(5.5, 4.0 + Double(score) * 0.05) }
    /// Tilt in radians. The log noses up after a flap and down while falling.
    var tilt: Double { max(-1.0, min(0.5, velocity * 0.06)) }

    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        random = SeededRandom(state: seed)
        while columns.count < 8 { appendColumn() }
    }

    private mutating func appendColumn() {
        let index = columns.last.map { $0.index + 1 } ?? 0
        let gapHalf = max(1.35, 1.75 - Double(index) * 0.01)
        var range = (gapHalf + 0.9)...(Self.worldHeight - gapHalf - 0.9)
        if let previous = columns.last {
            range = max(range.lowerBound, previous.gapCenter - 1.8)...min(range.upperBound, previous.gapCenter + 1.8)
        }
        let center = range.lowerBound + Double(random.next() % 10_000) / 10_000 * (range.upperBound - range.lowerBound)
        columns.append(FireColumn(index: index, x: Self.firstColumnX + Double(index) * Self.columnSpacing,
                                  gapCenter: center, gapHalf: gapHalf))
    }

    mutating func flap() {
        guard !gameOver else { return }
        started = true
        velocity = Self.flapVelocity
        flaps += 1
    }

    /// Advances by real elapsed time. Returns the number of columns passed during this call.
    @discardableResult mutating func advance(_ seconds: Double, autoplay: Bool = false) -> Int {
        accumulator += min(seconds, 0.25)
        var passed = 0
        while accumulator >= Self.step {
            accumulator -= Self.step
            if autoplay { self.autoplay() }
            passed += tick()
        }
        return passed
    }

    /// One fixed simulation step. Returns 1 when the log clears a column.
    mutating func tick() -> Int {
        guard started, !gameOver else { return 0 }
        time += Self.step; steps += 1
        velocity += Self.gravity * Self.step
        y += velocity * Self.step
        let previousX = x
        x += speed * Self.step
        var passed = 0
        for column in columns where previousX < column.x && x >= column.x { score += 1; passed += 1 }
        while let first = columns.first, first.x < x - 12 { columns.removeFirst() }
        while columns.count < 8 { appendColumn() }
        if collides() { gameOver = true }
        return passed
    }

    func collides() -> Bool {
        let top = y + Self.logRadius, bottom = y - Self.logRadius
        if bottom <= 0 || top >= Self.worldHeight { return true }
        for column in columns where abs(column.x - x) < Self.columnHalfWidth + Self.logHalfLength {
            if bottom < column.gapCenter - column.gapHalf || top > column.gapCenter + column.gapHalf { return true }
        }
        return false
    }

    /// The first column whose far edge the log has not yet passed.
    var nextColumn: FireColumn? {
        columns.first { $0.x + Self.columnHalfWidth + Self.logHalfLength > x }
    }

    /// Deterministic autopilot for benchmarks. Every 6 steps it searches flap sequences over the next
    /// 2.5 seconds, trying the heuristic's choice first, and takes the first move of a path that survives.
    /// Paths that reach a similar height and speed at the same time share one dead-end record.
    mutating func autoplay() {
        if !started { flap(); return }
        guard steps % 6 == 0 else { return }
        var budget = 20_000
        var deadEnds = Set<SIMD3<Int32>>()
        let plan = Self.search(self, depth: 50, budget: &budget, deadEnds: &deadEnds)
        if plan ?? wantsFlap() { flap() }
    }

    private static func search(_ state: FlappyEngine, depth: Int, budget: inout Int,
                               deadEnds: inout Set<SIMD3<Int32>>) -> Bool? {
        guard depth > 0 else { return false }
        let key = SIMD3<Int32>(Int32(depth), Int32((state.y * 25).rounded()), Int32((state.velocity * 4).rounded()))
        guard !deadEnds.contains(key) else { return nil }
        let preferred = state.wantsFlap()
        for choice in [preferred, !preferred] {
            guard budget > 0 else { return nil }
            budget -= 1
            var trial = state
            if choice { trial.flap() }
            for _ in 0..<6 where !trial.gameOver { _ = trial.tick() }
            if !trial.gameOver && search(trial, depth: depth - 1, budget: &budget, deadEnds: &deadEnds) != nil {
                return choice
            }
        }
        if budget > 0 { deadEnds.insert(key) }
        return nil
    }

    /// A flap lifts the log about 1.4 units, so the heuristic flaps just below the gap's center.
    /// Inside a column it already leans toward the following gap.
    private func wantsFlap() -> Bool {
        let ahead = columns.filter { $0.x + Self.columnHalfWidth + Self.logHalfLength > x }
        guard let current = ahead.first else { return false }
        let bounce = Self.flapVelocity * Self.flapVelocity / (-2 * Self.gravity)
        var aim = current.gapCenter - 0.7
        if x + Self.logHalfLength > current.x - Self.columnHalfWidth, ahead.count > 1 {
            let low = current.gapCenter - current.gapHalf + Self.logRadius + 0.12
            let high = current.gapCenter + current.gapHalf - Self.logRadius - 0.12 - bounce
            aim = max(low, min(high, ahead[1].gapCenter - 0.7))
        }
        return y < aim && velocity < 2
    }
}
