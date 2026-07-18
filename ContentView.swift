import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var phoneSession = PhoneSessionManager.shared
    @StateObject private var contactsManager = EmergencyContactsManager()
    @State private var caneConnection = CaneConnection()
    @State private var lastEvent: ObstacleEvent?
    @State private var audioEnabled = true
    private let synthesizer = AVSpeechSynthesizer()

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                statusSection
                Toggle("AI audio alerts", isOn: $audioEnabled)
                    .padding(.horizontal)
                NavigationLink("Emergency contacts") {
                    EmergencyContactsView(manager: contactsManager)
                }
                Spacer()
            }
            .padding()
            .navigationTitle("Cane Companion")
            .onAppear(perform: connectToCane)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(phoneSession.isWatchReachable ? "Watch connected" : "Watch not reachable",
                  systemImage: phoneSession.isWatchReachable ? "applewatch" : "applewatch.slash")
            if let event = lastEvent {
                Text("Last alert: \(event.direction) — \(event.label ?? "obstacle") (\(Int(event.distanceCm)) cm)")
                    .font(.subheadline)
            }
        }
    }

    private func connectToCane() {
        caneConnection.onObstacle = { event in
            DispatchQueue.main.async {
                lastEvent = event
                if let direction = PhoneSessionManager.HapticDirection(rawValue: event.direction) {
                    phoneSession.sendHaptic(direction)
                }
                if audioEnabled, let label = event.label {
                    speak(label)
                }
            }
        }
        // Replace with the UNO Q's actual address on the shared network
        caneConnection.connect(to: "ws://192.168.1.42:8765")
    }

    private func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        synthesizer.speak(utterance)
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
