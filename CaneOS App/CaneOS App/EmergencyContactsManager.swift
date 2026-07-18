import Foundation

enum ContactPriority: String, Codable {
    case primary, secondary, none
}

struct EmergencyContact: Identifiable, Codable {
    let id: UUID
    var name: String
    var phoneNumber: String
    var priority: ContactPriority

    enum CodingKeys: String, CodingKey {
        case id, name, phoneNumber, priority
    }

    init(id: UUID, name: String, phoneNumber: String, priority: ContactPriority = .none) {
        self.id = id
        self.name = name
        self.phoneNumber = phoneNumber
        self.priority = priority
    }

    // Graceful fallback for contacts saved before priority was added
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = try c.decode(UUID.self, forKey: .id)
        name        = try c.decode(String.self, forKey: .name)
        phoneNumber = try c.decode(String.self, forKey: .phoneNumber)
        priority    = try c.decodeIfPresent(ContactPriority.self, forKey: .priority) ?? .none
    }
}

final class EmergencyContactsManager: ObservableObject {
    static let shared = EmergencyContactsManager()

    @Published var contacts: [EmergencyContact] = []
    private let storageKey = "emergencyContacts"

    private init() { load() }

    /// Primary first, secondary second, then the rest sorted A–Z.
    var sortedContacts: [EmergencyContact] {
        let primary   = contacts.filter { $0.priority == .primary }
        let secondary = contacts.filter { $0.priority == .secondary }
        let rest      = contacts.filter { $0.priority == .none }
                                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return primary + secondary + rest
    }

    func add(name: String, phoneNumber: String, priority: ContactPriority = .none) {
        if priority != .none {
            for i in contacts.indices where contacts[i].priority == priority {
                contacts[i].priority = .none
            }
        }
        contacts.append(EmergencyContact(id: UUID(), name: name, phoneNumber: phoneNumber, priority: priority))
        save()
    }

    func remove(at offsets: IndexSet) {
        contacts.remove(atOffsets: offsets)
        save()
    }

    /// Assign a priority to one contact; any existing holder of that priority is demoted to none.
    func setPriority(_ priority: ContactPriority, for id: UUID) {
        if priority != .none {
            for i in contacts.indices where contacts[i].priority == priority {
                contacts[i].priority = .none
            }
        }
        if let i = contacts.firstIndex(where: { $0.id == id }) {
            contacts[i].priority = priority
        }
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