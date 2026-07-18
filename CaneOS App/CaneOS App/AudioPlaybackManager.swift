import Foundation
import AVFoundation

final class AudioPlaybackManager: NSObject, AVAudioPlayerDelegate {
    static let shared = AudioPlaybackManager()
    private var player: AVAudioPlayer?
    // Clips queue instead of replacing the active player, so back-to-back
    // narrations (e.g. a hazard alert followed by the "you've been here
    // before" callback) never talk over each other.
    private var pending: [Data] = []

    private override init() {
        super.init()
        configureSession()
    }

    private func configureSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            // .allowBluetoothA2DP routes to Bluetooth headphones/speakers;
            // .duckOthers softens any other audio (e.g. music) while alerts play
            try session.setCategory(.playback, options: [.allowBluetoothA2DP, .duckOthers])
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
