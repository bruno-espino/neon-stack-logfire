import AVFoundation
import Foundation

@main struct FeedbackTests {
    static func main() throws {
        let effect = ClearAnimation(rows: [16, 17, 18, 19], allClear: true, started: 10)
        precondition(effect.rowMask == 0xF0000 && effect.title == "ALL CLEAR!")
        precondition(effect.uniforms(at: 10).x == 0 && effect.uniforms(at: 12).x == -1)
        precondition(effect.uniforms(at: 10.2, reducedMotion: true).w == 1)
        precondition(ClearAnimation(rows: [19], allClear: false, started: 0).title == "1 LINE")
        precondition(ClearAnimation(rows: [16, 17, 18, 19], allClear: false, started: 0).title == "FOUR ROWS!")
        for cue in SoundCue.allCases {
            let wave = cue.waveData()
            let player = try AVAudioPlayer(data: wave, fileTypeHint: AVFileType.wav.rawValue)
            precondition(player.numberOfChannels == 1 && player.duration > 0 && player.duration < 1)
            precondition(wave.count > 44 && wave.prefix(4) == Data("RIFF".utf8))
        }
        if !CommandLine.arguments.contains("--no-playback") {
            let player = try AVAudioPlayer(data: SoundCue.allClear.waveData())
            precondition(player.play() && player.isPlaying, "The native player must start the generated all-clear sound")
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            precondition(!player.isPlaying, "The sound must finish without a retained playback loop")
        }
        print("Animation timing, clear labels, seven sound cues, and audio decoding passed")
    }
}
