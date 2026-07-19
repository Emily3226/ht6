import Foundation
import AVFoundation
import WatchConnectivity
import WatchKit
internal import Combine

/// Watch-side half of "Ask Cane": records from the WATCH microphone and
/// live-streams the audio to the phone, which runs speech recognition
/// (watchOS has no Speech framework), detects end-of-speech, queries the
/// backend, and speaks the answer. The phone mirrors every state change
/// back so this class can drive the Watch UI:
///
///   idle → (double-pinch) → capturing (streaming mic audio)
///        → phone detects silence → thinking (phone waiting on backend)
///        → answer arrives → idle (+ reply text shown)
///
/// Double-pinch is context-aware: start talking / finish early / CANCEL
/// while thinking (for accidental triggers or misheard requests).
final class WatchVoiceManager: NSObject, ObservableObject {
    static let shared = WatchVoiceManager()

    enum VoiceState: Equatable { case idle, capturing, thinking }

    @Published var state: VoiceState = .idle
    @Published var transcript: String = ""
    @Published var lastReply: String = ""

    private let audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var isStreaming = false

    /// 16 kHz mono Int16 — small enough to stream over WCSession
    /// (~32 KB/s) and exactly what the phone feeds its recognizer.
    private static let streamFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
    )!

    // MARK: - The double-pinch / button entry point

    func toggle() {
        switch state {
        case .idle:
            start()
        case .capturing:
            // Finish early — the phone finalizes whatever it heard so far.
            sendControl("stop")
        case .thinking:
            // Cancel the in-flight request (accidental trigger / misheard).
            sendControl("cancel")
            DispatchQueue.main.async { self.state = .idle }
            WKInterfaceDevice.current().play(.retry)
        }
    }

    private func start() {
        guard WCSession.default.isReachable else {
            WKInterfaceDevice.current().play(.failure)
            return
        }
        Task { [weak self] in
            let granted = await AVAudioApplication.requestRecordPermission()
            await MainActor.run {
                guard granted else {
                    WKInterfaceDevice.current().play(.failure)
                    return
                }
                self?.beginStreaming()
            }
        }
    }

    private func beginStreaming() {
        // Flip the UI and buzz FIRST — the red listening circle must appear
        // the instant the user pinches, not after the audio engine spins up
        // (engine + session setup can take a noticeable fraction of a second).
        transcript = ""
        lastReply = ""
        state = .capturing
        WKInterfaceDevice.current().play(.start)
        sendControl("start")

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
        } catch {
            print("[WatchVoice] audio session error: \(error.localizedDescription)")
            state = .idle
            sendControl("cancel")
            return
        }

        let input = audioEngine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inputFormat, to: Self.streamFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            self?.streamChunk(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("[WatchVoice] engine error: \(error.localizedDescription)")
            state = .idle
            sendControl("cancel")
            return
        }

        isStreaming = true
    }

    /// Audio-thread callback: downsample the chunk and ship it to the phone.
    private func streamChunk(_ buffer: AVAudioPCMBuffer) {
        guard isStreaming, let converter else { return }
        let ratio = Self.streamFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.streamFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let channel = out.int16ChannelData else { return }

        let data = Data(bytes: channel[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        if WCSession.default.isReachable {
            WCSession.default.sendMessageData(data, replyHandler: nil, errorHandler: nil)
        }
    }

    private func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func sendControl(_ value: String) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["voice": value], replyHandler: nil)
    }

    // MARK: - Mirrored state from the phone

    func applyRemoteState(_ stateName: String) {
        DispatchQueue.main.async {
            switch stateName {
            case "capturing":
                if !self.isStreaming { self.state = .capturing }  // phone-mic capture also mirrors
            case "thinking":
                self.stopStreaming()
                self.state = .thinking
            default: // "idle", "denied"
                self.stopStreaming()
                self.state = .idle
            }
        }
    }

    func applyRemoteTranscript(_ text: String) {
        DispatchQueue.main.async { self.transcript = text }
    }

    func applyReply(_ text: String) {
        DispatchQueue.main.async {
            self.lastReply = text
            WKInterfaceDevice.current().play(.success)
        }
    }

    // MARK: - Answer audio playback (on the Watch speaker / paired buds)

    private var player: AVAudioPlayer?

    /// ElevenLabs MP3 audio for the answer, synthesized on the phone and
    /// shipped here so the voice comes out of the WATCH, not the phone.
    func playAnswer(_ data: Data) {
        DispatchQueue.main.async {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                self.player = try AVAudioPlayer(data: data)
                self.player?.prepareToPlay()
                self.player?.play()
            } catch {
                print("[WatchVoice] playback error: \(error.localizedDescription)")
            }
        }
    }
}
