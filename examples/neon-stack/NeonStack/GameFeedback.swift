import AVFoundation
import Foundation

struct ClearAnimation {
    let rows: [Int]
    let allClear: Bool
    let started: Double
    var duration: Double { allClear ? 1.6 : (rows.count == 4 ? 1.1 : 0.65) }
    var title: String {
        allClear ? "ALL CLEAR!" : (rows.count == 4 ? "FOUR ROWS!" : "\(rows.count) \(rows.count == 1 ? "LINE" : "LINES")")
    }
    func uniforms(at time: Double, reducedMotion: Bool = false) -> SIMD4<Float> {
        let age = time - started
        guard age >= 0 && age < duration else { return SIMD4<Float>(-1, 0, 0, 0) }
        return SIMD4<Float>(Float(age / duration), Float(rows.count), allClear ? 1 : 0, reducedMotion ? 1 : 0)
    }
    var rowMask: UInt32 { rows.reduce(UInt32(0)) { $0 | (UInt32(1) << UInt32($1)) } }
}

enum SoundCue: CaseIterable {
    case rotate, hold, lock, line, four, allClear, gameOver
    var notes: [Double] {
        switch self {
        case .rotate: return [440]
        case .hold: return [392, 523.25]
        case .lock: return [130.81]
        case .line: return [523.25, 659.25, 783.99]
        case .four: return [523.25, 659.25, 783.99, 1046.5]
        case .allClear: return [523.25, 659.25, 783.99, 1046.5, 1318.51, 1567.98]
        case .gameOver: return [392, 329.63, 261.63, 196]
        }
    }
    var noteSeconds: Double {
        switch self {
        case .rotate: return 0.045
        case .hold, .lock: return 0.07
        case .line: return 0.085
        case .four: return 0.11
        case .allClear: return 0.14
        case .gameOver: return 0.15
        }
    }
    func waveData() -> Data {
        let sampleRate = 22050
        let noteFrames = Int(Double(sampleRate) * noteSeconds)
        let dataSize = noteFrames * notes.count * 2
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(36 + dataSize)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(dataSize))
        for frequency in notes {
            for frame in 0..<noteFrames {
                let time = Double(frame) / Double(sampleRate)
                let envelope = min(1, time / 0.004) * pow(1 - Double(frame) / Double(noteFrames), 1.6)
                let phase = 2 * Double.pi * frequency * time
                let sample = (sin(phase) + 0.22 * sin(phase * 2)) * envelope * 0.2
                append(Int16(sample * Double(Int16.max)))
            }
        }
        return data
    }
}

final class GameAudio {
    private var players: [SoundCue: AVAudioPlayer] = [:]
    init() {
        for cue in SoundCue.allCases {
            do {
                let player = try AVAudioPlayer(data: cue.waveData(), fileTypeHint: AVFileType.wav.rawValue)
                player.volume = 0.45
                players[cue] = player
            } catch { print("Sound unavailable: \(error.localizedDescription)") }
        }
    }
    func play(_ cue: SoundCue) {
        guard let player = players[cue] else { return }
        player.currentTime = 0
        if !player.play() { print("Sound playback unavailable") }
    }
    func stop() { for player in players.values { player.pause(); player.currentTime = 0 } }
}
