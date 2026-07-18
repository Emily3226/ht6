import SwiftUI

struct ContentView: View {
    @StateObject private var phoneSession = PhoneSessionManager.shared
    @StateObject private var contactsManager = EmergencyContactsManager()
    @State private var caneConnection = CaneConnection()
    @State private var sosManager = SOSManager()

    private let elevenLabs = ElevenLabsClient(apiKey: Config.elevenLabsAPIKey, voiceId: Config.elevenLabsVoiceId)
    private let backboard = BackboardClient(apiKey: Config.backboardAPIKey)

    @State private var lastHazard: CaneMessage?
    @State private var isScanning = false

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                statusSection

                Button(action: requestSceneDescription) {
                    Label(isScanning ? "Scanning..." : "What's around me?", systemImage: "camera.viewfinder")
                }
                .disabled(isScanning)
                .buttonStyle(.borderedProminent)

                NavigationLink("Emergency contacts") {
                    EmergencyContactsView(manager: contactsManager)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Cane Companion")
            .onAppear(perform: connectToBackend)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(phoneSession.isWatchReachable ? "Watch connected" : "Watch not reachable",
                  systemImage: phoneSession.isWatchReachable ? "applewatch" : "applewatch.slash")
            if let hazard = lastHazard {
                Text("Last alert: \(hazard.direction ?? "-") — \(hazard.hazardType ?? "hazard") (\(hazard.urgency ?? "-"))")
                    .font(.subheadline)
            }
        }
    }

    // MARK: Backend connection + message routing

    private func connectToBackend() {
        caneConnection.onMessage = { message in
            Task { @MainActor in
                switch message.type {
                case "hazard":
                    handleHazard(message)
                case "scene_description":
                    await handleSceneDescription(message)
                default:
                    break
                }
            }
        }
        caneConnection.connect(to: Config.backendWebSocketURL)
    }

    // MARK: Branch 1 & 2 -- hazard audio, and SOS for high urgency

    private func handleHazard(_ hazard: CaneMessage) {
        lastHazard = hazard
        isScanning = false

        if let direction = hazard.direction,
           let hapticDirection = PhoneSessionManager.HapticDirection(rawValue: direction) {
            phoneSession.sendHaptic(hapticDirection)
        }

        guard let description = hazard.spokenDescription else { return }

        if hazard.urgency == "high" {
            // Fire SOS and TTS in parallel -- SOS must not wait on TTS finishing
            Task {
                async let audioTask: Void = speakAndPlay(description)
                async let sosTask: Void = fireSOS()
                _ = await (audioTask, sosTask)
            }
        } else {
            Task { await speakAndPlay(description) }
        }
    }

    private func fireSOS() async {
        do {
            let location = try await sosManager.requestLocation()
            try await sosManager.sendEmergencyAlert(
                to: contactsManager.contacts,
                location: location,
                accountSid: Config.twilioAccountSid,
                authToken: Config.twilioAuthToken,
                fromNumber: Config.twilioFromNumber
            )
        } catch {
            print("SOS failed: \(error.localizedDescription)")
        }
    }

    // MARK: Branch 3 -- on-demand "what's around me", Backboard-backed

    private func requestSceneDescription() {
        isScanning = true
        caneConnection.sendCommand("scan_now")
    }

    private func handleSceneDescription(_ message: CaneMessage) async {
        isScanning = false
        guard let text = message.text else { return }
        do {
            let reply = try await backboard.send(text: text)
            await speakAndPlay(reply)
        } catch {
            print("Backboard call failed: \(error.localizedDescription)")
            await speakAndPlay(text) // fall back to speaking the raw description
        }
    }

    // MARK: Shared TTS helper

    private func speakAndPlay(_ text: String) async {
        do {
            let audio = try await elevenLabs.synthesize(text: text)
            AudioPlaybackManager.shared.play(audio)
        } catch {
            print("ElevenLabs synthesis failed: \(error.localizedDescription)")
        }
    }
}

struct EmergencyContactsView: View {
    @ObservedObject var manager: EmergencyContactsManager
    @State private var name = ""
    @State private var phone = ""

    var body: some View {
        List {
            Section("Add contact") {
                TextField("Name", text: $name)
                TextField("Phone number", text: $phone)
                    .keyboardType(.phonePad)
                Button("Add") {
                    guard !name.isEmpty, !phone.isEmpty else { return }
                    manager.add(name: name, phoneNumber: phone)
                    name = ""; phone = ""
                }
            }
            Section("Contacts") {
                ForEach(manager.contacts) { contact in
                    VStack(alignment: .leading) {
                        Text(contact.name).font(.headline)
                        Text(contact.phoneNumber).font(.subheadline)
                    }
                }
                .onDelete(perform: manager.remove)
            }
        }
        .navigationTitle("Emergency contacts")
    }
}
