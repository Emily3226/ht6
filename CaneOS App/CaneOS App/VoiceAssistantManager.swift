import Foundation
import Speech
import AVFoundation
import Combine

/// Voice capture for "Ask Cane".
///
/// Trigger: the Apple Watch double-pinch gesture (system Double Tap) — the
/// Watch messages the phone, which calls `wakeFromGesture()` — or a manual
/// tap on the phone's mic button. There is no wake word.
///
/// Capture: on-device transcription (Apple Speech) runs until the user
/// stops talking (~2s of silence), then the finished string is handed to
/// `onCommand`, which ships it to the Python backend as a question. The
/// backend's answer comes back over the WebSocket and is spoken aloud.
@MainActor
final class VoiceAssistantManager: NSObject, ObservableObject {
    enum AssistantState: Equatable {
        case idle           // waiting for a double-pinch (or mic tap)
        case capturing      // actively transcribing the user's request
        case thinking       // question sent; waiting for the answer
        case denied         // mic or speech permission refused
    }

    @Published var state: AssistantState = .idle
    @Published var transcript: String = ""
    @Published var lastReply: String = ""

    /// Called with the final transcribed request once the user stops talking.
    var onCommand: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var lastTranscriptChange = Date()
    private var captureBegan = Date()
    private var silenceTimer: Timer?

    private let silenceCutoff: TimeInterval = 1.8
    private let emptyCaptureTimeout: TimeInterval = 8
    private let maxCaptureSeconds: TimeInterval = 15

    // MARK: - Public controls

    /// Requests mic + speech permissions up front so the first double-pinch
    /// doesn't stall on permission dialogs. Safe to call repeatedly.
    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor in
                guard authStatus == .authorized else {
                    self?.state = .denied
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        self?.state = granted ? .idle : .denied
                    }
                }
            }
        }
    }

    /// The Watch's double-pinch gesture (or the phone's mic button): start
    /// capturing immediately.
    func wakeFromGesture() {
        switch state {
        case .idle:
            beginCapture()
        case .denied:
            requestPermissions()
        case .capturing, .thinking:
            break
        }
    }

    /// The phone mic button: start capturing, or finish a capture early
    /// instead of waiting out the silence cutoff.
    func manualToggle() {
        switch state {
        case .idle:
            beginCapture()
        case .capturing:
            finalizeCapture()
        case .denied:
            requestPermissions()
        case .thinking:
            break
        }
    }

    /// Called by the owner once the reply has been handled.
    func finishedThinking() {
        state = .idle
    }

    // MARK: - Command capture

    private func beginCapture() {
        startRecognition()
        guard state != .denied else { return }
        state = .capturing
        captureBegan = Date()
        lastTranscriptChange = Date()

        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForEndOfSpeech() }
        }
    }

    private func checkForEndOfSpeech() {
        guard state == .capturing else { return }
        let quiet = Date().timeIntervalSince(lastTranscriptChange)
        let elapsed = Date().timeIntervalSince(captureBegan)

        if !transcript.isEmpty && quiet >= silenceCutoff {
            finalizeCapture()
        } else if transcript.isEmpty && elapsed >= emptyCaptureTimeout {
            // Woke up but heard nothing — back to idle.
            stopCapture()
            state = .idle
        } else if elapsed >= maxCaptureSeconds {
            finalizeCapture()
        }
    }

    private func finalizeCapture() {
        let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopCapture()
        guard !command.isEmpty else {
            state = .idle
            return
        }
        state = .thinking
        onCommand?(command)
    }

    // MARK: - Speech recognition plumbing

    private func startRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            state = .denied
            return
        }
        stopCapture()
        transcript = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            print("[Voice] audio engine error: \(error.localizedDescription)")
            state = .idle
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            Task { @MainActor in
                guard let self, let result else { return }
                let text = result.bestTranscription.formattedString
                if text != self.transcript {
                    self.transcript = text
                    self.lastTranscriptChange = Date()
                }
            }
        }
    }

    private func stopCapture() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
}
