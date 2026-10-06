import Foundation

@main struct EngineTests {
    static func main() {
        var engine = GameEngine(seed: 777)
        let spawn = engine.piece
        for _ in 0..<30 { engine.move(dx: -1, dy: 0) }
        precondition(engine.piece.cells.allSatisfy { $0.x >= 0 }, "Pieces must stay inside the board")
        let before = engine.piece
        engine.move(dx: -1, dy: 0)
        precondition(engine.piece.x == before.x, "Blocked movement must leave the piece unchanged")
        engine.piece = spawn
        let landing = engine.landing(spawn)
        engine.hardDrop()
        precondition(landing.cells.allSatisfy { engine.board[$0.y * 10 + $0.x] != 0 }, "Hard drop must lock all cells")
        precondition(engine.piecesLocked == 1 && engine.score > 0, "Hard drop must score and advance the queue")
        var rows = GameEngine(seed: 1)
        rows.board[199] = 3
        for row in 16..<20 { for column in 0..<10 { rows.board[row * 10 + column] = 2 } }
        rows.board[150] = 7
        precondition(rows.clearRows() == 4 && rows.lines == 4, "Four full lines must clear together")
        precondition(rows.board[190] == 7 && rows.board[0] == 0, "Rows above clears must fall by four rows")
        precondition(rows.lastClearRows == [16, 17, 18, 19] && !rows.lastAllClear,
                     "Clear feedback must retain the original row positions without claiming an empty board")
        var singleClear = GameEngine.clearDemo("single")!; singleClear.hardDrop()
        precondition(singleClear.lastClear == 1 && !singleClear.lastAllClear && singleClear.lastClearRows == [19],
                     "A single clear with remaining cells must not count as an all clear")
        var fourClear = GameEngine.clearDemo("four")!; fourClear.hardDrop()
        precondition(fourClear.lastClear == 4 && !fourClear.lastAllClear && fourClear.board.contains(7),
                     "A four-row clear must preserve cells above the cleared rows")
        var allClear = GameEngine.clearDemo("all-clear")!; allClear.hardDrop()
        precondition(allClear.lastClear == 4 && allClear.lastAllClear && allClear.board.allSatisfy { $0 == 0 },
                     "An all clear requires both a clear and an empty locked board")
        var oneRowAllClear = GameEngine(seed: 777)
        for column in 0..<10 where !(3...6).contains(column) { oneRowAllClear.board[190 + column] = 2 }
        oneRowAllClear.piece = Piece(kind: 0)
        oneRowAllClear.hardDrop()
        precondition(oneRowAllClear.lastClear == 1 && oneRowAllClear.lastAllClear,
                     "An all clear can follow a single-row clear")
        allClear.hardDrop()
        precondition(allClear.lastClear == 0 && !allClear.lastAllClear && allClear.lastClearRows.isEmpty,
                     "The next ordinary lock must reset the clear feedback")
        var square = GameEngine(seed: 1); square.piece = Piece(kind: 1)
        let cells = square.piece.cells; square.rotate()
        precondition(square.piece.cells == cells, "Square rotation must preserve its cells")
        var over = GameEngine(seed: 2); over.nextKind = 1
        over.board[4] = 1; over.piece = Piece(kind: 1, y: 18); over.lock()
        precondition(over.gameOver, "An occupied spawn must end the game")
        var hold = GameEngine(seed: 777)
        let originalKind = hold.piece.kind; let queuedKind = hold.nextKind
        var queueControl = hold; queueControl.hardDrop()
        hold.move(dx: -2, dy: 4); hold.rotate()
        precondition(hold.hold(), "An empty hold must accept the active piece")
        precondition(hold.heldKind == originalKind && hold.piece.kind == queuedKind && hold.nextKind == queueControl.nextKind,
                     "An empty hold must store the active piece and advance the queue once")
        precondition(hold.piece.rotation == 0 && hold.piece.x == 3 && hold.piece.y == 0 && hold.score == 0,
                     "Hold must reset the spawn pose without awarding drop points")
        let nextAfterHold = hold.nextKind
        precondition(!hold.hold() && hold.heldKind == originalKind && hold.piece.kind == queuedKind && hold.nextKind == nextAfterHold,
                     "A second hold must leave both slots and the queue unchanged")
        hold.hardDrop()
        precondition(hold.canHold, "Locking a piece must make hold available again")
        let outgoing = hold.piece.kind; let queuedBeforeSwap = hold.nextKind
        hold.move(dx: 1, dy: 2); hold.rotate()
        precondition(hold.hold() && hold.piece.kind == originalKind && hold.heldKind == outgoing,
                     "An occupied hold must swap both pieces")
        precondition(hold.nextKind == queuedBeforeSwap && hold.piece.rotation == 0 && hold.piece.x == 3 && hold.piece.y == 0,
                     "A swap must reset the pose without consuming the queue")
        var blockedHold = GameEngine(seed: 1); blockedHold.nextKind = 1; blockedHold.board[4] = 7
        precondition(blockedHold.hold() && blockedHold.gameOver && !blockedHold.hold(),
                     "A blocked hold spawn must end the game and reject further swaps")
        var heldBlocked = GameEngine(seed: 1)
        heldBlocked.heldKind = 1; heldBlocked.board[4] = 7
        precondition(heldBlocked.hold() && heldBlocked.gameOver,
                     "A blocked occupied hold spawn must end the game")
        let restarted = GameEngine(seed: 777)
        precondition(restarted.heldKind == nil && restarted.canHold, "A new game must clear the hold slot")
        var first = GameEngine(seed: 777); var second = GameEngine(seed: 777)
        for _ in 0..<100 { first.autoplay(); second.autoplay() }
        precondition(first.board == second.board && first.score == second.score, "Seeded replays must match")
        precondition(first.lines > 10 && !first.gameOver, "Benchmark replay must exercise line clears")
        print("Hold, movement, scoring, line-clear, and replay checks passed. Replay lines: \(first.lines), score: \(first.score)")
    }
}
