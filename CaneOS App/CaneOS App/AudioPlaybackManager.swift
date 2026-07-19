import Foundation
import AVFoundation

final class AudioPlaybackManager: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlaybackManager()
    private var player: AVAudioPlayer?
    // Clips queue instead of replacing the active player, so back-to-back
    // narrations (e.g. a hazard alert followed by the "you've been here
    // before" callback) never talk over each other.
    private var pending: [Data] = []

    /// True while narration audio is playing or queued — the voice assistant
    /// checks this so our own TTS can't trigger the wake word.
    var isAudioPlaying: Bool { player?.isPlaying == true || !pending.isEmpty }

    private override init() {
        super.init()
        configureSession()
    }

    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .playAndRecord so the voice assistant's mic tap and narration
            // playback share one session; .defaultToSpeaker keeps playback
            // loud (not the earpiece); .allowBluetoothA2DP routes to
            // Bluetooth headphones; .duckOthers softens other audio.
            try session.setCategory(.playAndRecord,
                                    options: [.allowBluetoothA2DP, .defaultToSpeaker, .duckOthers])
            try session.setActive(true)
        } catch {
            print("Audio session error: \(error.localizedDescription)")
        }
    }

    func play(_ data: Data) {
        if player?.isPlaying == true {
            pending.append(data)
            return
        }
        start(data)
    }

    private func start(_ data: Data) {
        do {
            player = try AVAudioPlayer(data: data)
            player?.delegate = self
            player?.prepareToPlay()
            player?.play()
        } catch {
            print("Playback error: \(error.localizedDescription)")
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard !pending.isEmpty else { return }
        start(pending.removeFirst())
    }
}
