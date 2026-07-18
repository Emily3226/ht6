import Foundation

struct EmergencyContact: Identifiable, Codable {
    let id: UUID
    var name: String
    var phoneNumber: String
}

final class EmergencyContactsManager: ObservableObject {
    @Published var contacts: [EmergencyContact] = []
    private let storageKey = "emergencyContacts"

    init() { load() }

    func add(name: String, phoneNumber: String) {
        contacts.append(EmergencyContact(id: UUID(), name: name, phoneNumber: phoneNumber))
        save()
    }

    func remove(at offsets: IndexSet) {
        contacts.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([EmergencyContact].self, from: data) {
            contacts = saved
        }
    }
}
