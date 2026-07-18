import Foundation
import AVFoundation

final class AudioPlaybackManager: NSObject {
    static let shared = AudioPlaybackManager()
    private var player: AVAudioPlayer?

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
        do {
            player = try AVAudioPlayer(data: data)
            player?.prepareToPlay()
            player?.play()
        } catch {
            print("Playback error: \(error.localizedDescription)")
        }
    }
}
