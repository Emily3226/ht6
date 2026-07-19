import Foundation
import Speech
import AVFoundation
import Combine

/// Hands-free voice input + short-term event memory for "Ask Cane".
///
/// Flow: passively listen for the wake phrase ("Hey Cane") → capture the
/// spoken request, transcribing on-device → auto-finish when the user stops
/// talking (~2s of silence) → hand the final text to `onCommand` (which
/// routes it to the Python backend for scans, or Backboard for questions).
///
/// Two ways to wake it, both free:
/// 1. Say "Hey Cane" — Apple-Speech continuously transcribes on-device and
///    watches partial results for the wake phrase.
/// 2. Double-pinch on the Apple Watch (the watchOS Double Tap gesture) —
///    the Watch messages the phone, which calls `wakeFromGesture()`.
///
/// The manager also keeps a rolling buffer of recent detections (hazards,
/// scan results) that gets injected into Backboard queries as context, so
/// "what's happening right now?" reflects the last few minutes while
/// Backboard's thread memory keeps the longer conversation non-repetitive.
@MainActor
final class VoiceAssistantManager: NSObject, ObservableObject {
    enum AssistantState: Equatable {
        case idle           // voice off (permissions pending or error)
        case wakeListening  // waiting for "Hey Cane"
        case capturing      // actively transcribing the user's request
        case thinking       // request handed off; waiting for the answer
        case denied         // mic or speech permission refused
    }

    @Published var state: AssistantState = .idle
    @Published var transcript: String = ""     // the command portion, for UI
    @Published var lastReply: String = ""

    /// Called with the final transcribed request once the user stops talking.
    var onCommand: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    // Apple-Speech wake bookkeeping
    private var fullTranscript = ""
    private var commandStart: String.Index?    // where the command begins (after wake phrase)
    private var lastTranscriptChange = Date()
    private var captureBegan = Date()
    private var silenceTimer: Timer?
    private var restartTimer: Timer?

    private static let wakeVariants = ["hey cane", "hey kane", "hey came", "hey cain", "hey kain"]
    private let silenceCutoff: TimeInterval = 1.8
    private let emptyCaptureTimeout: TimeInterval = 8
    private let maxCaptureSeconds: TimeInterval = 15

    // MARK: - Recent-event memory

    struct Event {
        let date: Date
        let text: String
    }

    private(set) var recentEvents: [Event] = []
    private let maxEvents = 12

    /// Called for every hazard narration / scan result so questions can be
    /// answered with awareness of what the system recently saw.
    func recordEvent(_ text: String) {
        recentEvents.append(Event(date: Date(), text: text))
        if recentEvents.count > maxEvents {
            recentEvents.removeFirst(recentEvents.count - maxEvents)
        }
    }

    /// Recent events formatted for the Backboard prompt, newest first.
    func contextBlock() -> String {
        guard !recentEvents.isEmpty else { return "No events detected recently." }
        let now = Date()
        return recentEvents.reversed().map { event in
            let seconds = Int(now.timeIntervalSince(event.date))
            let age = seconds < 60 ? "\(seconds)s ago" : "\(seconds / 60)m ago"
            return "- (\(age)) \(event.text)"
        }.joined(separator: "\n")
    }

    /// True when the spoken request is asking for a fresh camera scan rather
    /// than a question about known context.
    static func isScanIntent(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let scanPhrases = ["scan", "around me", "surroundings", "what do you see",
                           "look around", "what's in front", "whats in front",
                           "describe the scene", "what is around"]
        return scanPhrases.contains { lowered.contains($0) }
    }

    // MARK: - Public controls

    /// Starts hands-free operation: requests permissions, then listens for
    /// the wake phrase indefinitely. Safe to call repeatedly.
    func startWakeWord() {
        guard state == .idle || state == .denied else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
            Task { @MainActor in
                guard authStatus == .authorized else {
                    self?.state = .denied
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self?.state = .denied
                            return
                        }
                        self?.enterWakeListening()
                    }
                }
            }
        }
    }

    /// The mic button: skip the wake word (start capturing immediately), or
    /// finish a capture early instead of waiting out the silence cutoff.
    func manualToggle() {
        switch state {
        case .idle, .denied:
            startWakeWord()
        case .wakeListening:
            beginCapture(resumingFromWake: false)
        case .capturing:
            finalizeCapture()
        case .thinking:
            break
        }
    }

    /// Called by the owner once the reply has been handled — resumes
    /// listening for the next "Hey Cane".
    func finishedThinking() {
        state = .idle
        enterWakeListening()
    }

    /// The Watch's double-pinch gesture: skip the wake word and start
    /// capturing the request immediately.
    func wakeFromGesture() {
        switch state {
        case .wakeListening, .idle:
            beginCapture(resumingFromWake: false)
        case .capturing, .thinking, .denied:
            break
        }
    }

    // MARK: - Wake listening

    private func enterWakeListening() {
        stopEverything()
        state = .wakeListening

        // Continuous Apple-Speech transcription, scanning partial results
        // for the wake phrase. Recognition tasks cap out around a minute,
        // so restart on a timer.
        startRecognition()
        restartTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .wakeListening else { return }
                self.startRecognition()
            }
        }
    }

    private func handleWakePartial(_ text: String) {
        guard state == .wakeListening else { return }
        // Ignore our own TTS leaking into the mic.
        guard !AudioPlaybackManager.shared.isAudioPlaying else { return }
        let lowered = text.lowercased()
        for variant in Self.wakeVariants {
            if let range = lowered.range(of: variant, options: .backwards) {
                // Wake phrase heard — keep the same recognition stream and
                // treat everything after the phrase as the command ("hey
                // cane, what's around me" works in one breath).
                commandStart = range.upperBound
                fullTranscript = text
                beginCapture(resumingFromWake: true)
                return
            }
        }
    }

    // MARK: - Command capture

    private func beginCapture(resumingFromWake: Bool) {
        restartTimer?.invalidate()
        restartTimer = nil

        if !resumingFromWake {
            startRecognition()   // fresh stream: the whole transcript is the command
            commandStart = nil
            fullTranscript = ""
        }
        state = .capturing
        captureBegan = Date()
        lastTranscriptChange = Date()
        updateCommandTranscript()

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
            // Woke up but heard nothing — go back to wake listening.
            state = .idle
            enterWakeListening()
        } else if elapsed >= maxCaptureSeconds {
            finalizeCapture()
        }
    }

    private func finalizeCapture() {
        let command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stopEverything()
        guard !command.isEmpty else {
            state = .idle
            enterWakeListening()
            return
        }
        state = .thinking
        onCommand?(command)
    }

    private func updateCommandTranscript() {
        if let commandStart, commandStart <= fullTranscript.endIndex {
            transcript = String(fullTranscript[commandStart...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
        } else {
            transcript = fullTranscript
        }
    }

    // MARK: - Speech recognition plumbing

    private func startRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            state = .denied
            return
        }
        tearDownRecognition()
        fullTranscript = ""
        commandStart = nil
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

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if text != self.fullTranscript {
                        self.fullTranscript = text
                        self.lastTranscriptChange = Date()
                        self.updateCommandTranscript()
                    }
                    if self.state == .wakeListening {
                        self.handleWakePartial(text)
                    }
                }
                if error != nil, self.state == .wakeListening {
                    // Recognition stream died while idle-listening — restart
                    // after a beat so wake detection keeps working.
                    try? await Task.sleep(for: .seconds(1))
                    if self.state == .wakeListening { self.startRecognition() }
                }
            }
        }
    }

    private func tearDownRecognition() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func stopEverything() {
        tearDownRecognition()
        silenceTimer?.invalidate()
        silenceTimer = nil
        restartTimer?.invalidate()
        restartTimer = nil
    }
}
