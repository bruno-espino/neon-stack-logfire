import Foundation

struct Cell: Equatable { var x: Int; var y: Int }

struct Piece {
    var kind: Int
    var rotation = 0
    var x = 3
    var y = 0
    var cells: [Cell] {
        let shapes = [
            [(0,1),(1,1),(2,1),(3,1)], [(1,0),(2,0),(1,1),(2,1)],
            [(1,0),(0,1),(1,1),(2,1)], [(1,0),(2,0),(0,1),(1,1)],
            [(0,0),(1,0),(1,1),(2,1)], [(0,0),(0,1),(1,1),(2,1)], [(2,0),(0,1),(1,1),(2,1)],
        ]
        return shapes[kind].map { original in
            var cell = Cell(x: original.0, y: original.1)
            if kind != 1 {
                for _ in 0..<rotation { cell = Cell(x: (kind == 0 ? 4 : 3) - 1 - cell.y, y: cell.x) }
            }
            return Cell(x: cell.x + x, y: cell.y + y)
        }
    }
}

struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

struct GameEngine {
    static let width = 10
    static let height = 20
    var board = Array(repeating: Int32(0), count: width * height)
    var piece = Piece(kind: 0)
    var nextKind = 0
    var heldKind: Int?
    private(set) var holdUsed = false
    var score = 0
    var lines = 0
    var gameOver = false
    var piecesLocked = 0
    var lastClear = 0
    private(set) var lastClearRows: [Int] = []
    private(set) var lastAllClear = false
    private var bag: [Int] = []
    private var random: SeededRandom
    var level: Int { 1 + lines / 10 }
    var canHold: Bool { !holdUsed && !gameOver }
    init(seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        random = SeededRandom(state: seed)
        piece = Piece(kind: drawKind())
        nextKind = drawKind()
    }
    static func clearDemo(_ scenario: String, seed: UInt64 = 777) -> GameEngine? {
        guard ["single", "four", "all-clear"].contains(scenario) else { return nil }
        var engine = GameEngine(seed: seed)
        let rowCount = scenario == "single" ? 1 : 4
        for row in (height - rowCount)..<height {
            for column in 0..<width where column != 4 { engine.board[row * width + column] = 6 }
        }
        if scenario == "four" { engine.board[100] = 7 }
        engine.piece = Piece(kind: 0, rotation: 1, x: 2)
        return engine
    }
    mutating func drawKind() -> Int {
        if bag.isEmpty { bag = Array(0...6).shuffled(using: &random) }
        return bag.removeLast()
    }
    func fits(_ candidate: Piece) -> Bool {
        candidate.cells.allSatisfy { cell in
            cell.x >= 0 && cell.x < Self.width && cell.y >= 0 && cell.y < Self.height
                && board[cell.y * Self.width + cell.x] == 0
        }
    }
    @discardableResult mutating func move(dx: Int, dy: Int) -> Bool {
        guard !gameOver else { return false }
        var candidate = piece
        candidate.x += dx; candidate.y += dy
        guard fits(candidate) else { return false }
        piece = candidate
        return true
    }
    mutating func rotate() {
        guard !gameOver else { return }
        var candidate = piece
        candidate.rotation = (candidate.rotation + 1) % 4
        for kick in [0, -1, 1, -2, 2] {
            candidate.x = piece.x + kick
            if fits(candidate) { piece = candidate; return }
        }
    }
    @discardableResult mutating func hold() -> Bool {
        guard canHold else { return false }
        let outgoing = piece.kind
        if let heldKind {
            piece = Piece(kind: heldKind)
        } else {
            piece = Piece(kind: nextKind)
            nextKind = drawKind()
        }
        heldKind = outgoing
        holdUsed = true
        gameOver = !fits(piece)
        return true
    }
    func landing(_ candidate: Piece) -> Piece {
        var dropped = candidate
        while true {
            var below = dropped; below.y += 1
            if !fits(below) { return dropped }
            dropped = below
        }
    }
    mutating func hardDrop() {
        guard !gameOver else { return }
        let dropped = landing(piece)
        score += (dropped.y - piece.y) * 2
        piece = dropped; lock()
    }
    mutating func step() { if !move(dx: 0, dy: 1) && !gameOver { lock() } }
    mutating func lock() {
        for cell in piece.cells { board[cell.y * Self.width + cell.x] = Int32(piece.kind + 1) }
        piecesLocked += 1
        lastClear = clearRows()
        score += [0, 100, 300, 500, 800][lastClear] * level
        piece = Piece(kind: nextKind); nextKind = drawKind()
        holdUsed = false
        gameOver = !fits(piece)
    }
    @discardableResult mutating func clearRows() -> Int {
        let rows = (0..<Self.height).map { Array(board[$0 * Self.width..<($0 + 1) * Self.width]) }
        let remaining = rows.filter { $0.contains(0) }
        lastClearRows = rows.indices.filter { !rows[$0].contains(0) }
        let cleared = Self.height - remaining.count
        board = Array(repeating: Int32(0), count: cleared * Self.width) + remaining.flatMap { $0 }
        lastAllClear = cleared > 0 && board.allSatisfy { $0 == 0 }
        lines += cleared
        return cleared
    }
    var displayCells: [Int32] {
        var result = board
        guard !gameOver else { return result }
        for cell in landing(piece).cells { result[cell.y * Self.width + cell.x] = Int32(piece.kind + 11) }
        for cell in piece.cells { result[cell.y * Self.width + cell.x] = Int32(piece.kind + 1) }
        return result
    }
    mutating func autoplay() {
        guard !gameOver else { return }
        var best = piece
        var bestCost = Double.infinity
        for rotation in 0..<4 {
            for x in -3..<Self.width {
                let candidate = Piece(kind: piece.kind, rotation: rotation, x: x, y: 0)
                guard fits(candidate) else { continue }
                let dropped = landing(candidate)
                var trial = self; trial.piece = dropped; trial.lock()
                var heights: [Int] = []
                var holes = 0
                for column in 0..<Self.width {
                    var occupied = false; var height = 0
                    for row in 0..<Self.height {
                        if trial.board[row * Self.width + column] != 0 {
                            if !occupied { height = Self.height - row }; occupied = true
                        } else if occupied { holes += 1 }
                    }
                    heights.append(height)
                }
                let bumps = zip(heights, heights.dropFirst()).reduce(0) { $0 + abs($1.0 - $1.1) }
                let cost = Double(heights.reduce(0, +)) * 0.5 + Double(holes) * 8
                    + Double(bumps) * 0.3 - Double(trial.lastClear) * 4
                if cost < bestCost { bestCost = cost; best = dropped }
            }
        }
        piece = best; hardDrop()
    }
}
