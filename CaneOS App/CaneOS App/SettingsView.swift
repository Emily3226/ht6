import SwiftUI

struct SettingsView: View {
    @StateObject private var hapticSettings = HapticSettings.shared
    @StateObject private var contactsManager = EmergencyContactsManager.shared
    @StateObject private var phoneSession = PhoneSessionManager.shared

    @State private var newName = ""
    @State private var newPhone = ""

    var body: some View {
        NavigationView {
            Form {
                hapticSection
                contactsSection
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: Haptic strength

    private var hapticSection: some View {
        Section {
            Picker("Buzz strength", selection: $hapticSettings.intensity) {
                ForEach(HapticIntensity.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                Image(systemName: phoneSession.isWatchReachable ? "applewatch" : "applewatch.slash")
                    .foregroundColor(phoneSession.isWatchReachable ? .green : .secondary)
                Text(phoneSession.isWatchReachable ? "Watch reachable" : "Watch not reachable — test will still queue")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Button("Test buzz on Watch") {
                phoneSession.sendHaptic(.up)
            }
        } header: {
            Text("Haptic feedback")
        } footer: {
            Text("Changes take effect on your Watch automatically. \"Strength\" controls how many times the Watch buzzes in a row — the Watch hardware doesn't support variable-intensity haptics for apps, so repetition stands in for intensity.")
        }
    }

    // MARK: Emergency contacts

    private var contactsSection: some View {
        Section {
            TextField("Name", text: $newName)
                .textContentType(.name)
            TextField("Phone number", text: $newPhone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
            Button("Add contact") {
                let trimmedName = newName.trimmingCharacters(in: .whitespaces)
                let trimmedPhone = newPhone.trimmingCharacters(in: .whitespaces)
                guard !trimmedName.isEmpty, !trimmedPhone.isEmpty else { return }
                contactsManager.add(name: trimmedName, phoneNumber: trimmedPhone)
                newName = ""
                newPhone = ""
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                      || newPhone.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Emergency contacts")
        } footer: {
            Text("These numbers receive an SMS with your location when a high-urgency hazard triggers SOS.")
        }

        Section {
            if contactsManager.contacts.isEmpty {
                Text("No contacts yet.").foregroundColor(.secondary)
            } else {
                ForEach(contactsManager.contacts) { contact in
                    VStack(alignment: .leading) {
                        Text(contact.name).font(.headline)
                        Text(contact.phoneNumber).font(.subheadline).foregroundColor(.secondary)
                    }
                }
                .onDelete(perform: contactsManager.remove)
            }
        }
    }
}

#Preview {
    SettingsView()
}