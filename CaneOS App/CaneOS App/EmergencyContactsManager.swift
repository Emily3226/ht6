import Foundation
import Combine
import SwiftUI

enum ContactPriority: String, Codable {
    case none, primary, secondary
}

enum Carrier: String, Codable, CaseIterable, Identifiable {
    case bell, telus, rogers, fido, koodo, virginPlus, freedom, videotron
    case verizon, att, tmobile, sprint

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bell:       return "Bell"
        case .telus:      return "Telus"
        case .rogers:     return "Rogers"
        case .fido:       return "Fido"
        case .koodo:      return "Koodo"
        case .virginPlus: return "Virgin Plus"
        case .freedom:    return "Freedom Mobile"
        case .videotron:  return "Vidéotron"
        case .verizon:    return "Verizon (US)"
        case .att:        return "AT&T (US)"
        case .tmobile:    return "T-Mobile (US)"
        case .sprint:     return "Sprint (US)"
        }
    }

    var gatewayDomain: String {
        switch self {
        case .bell:       return "txt.bell.ca"
        case .telus:      return "msg.telus.com"
        case .rogers:     return "pcs.rogers.com"
        case .fido:       return "fido.ca"
        case .koodo:      return "msg.koodomobile.com"
        case .virginPlus: return "vmobile.ca"
        case .freedom:    return "txt.freedommobile.ca"
        case .videotron:  return "videotron.ca"
        case .verizon:    return "vtext.com"
        case .att:        return "txt.att.net"
        case .tmobile:    return "tmomail.net"
        case .sprint:     return "messaging.sprintpcs.com"
        }
    }
}

struct EmergencyContact: Identifiable, Codable {
    let id: UUID
    var name: String
    var phoneNumber: String
    var carrier: Carrier
    var priority: ContactPriority = .none

    var smsGatewayAddress: String {
        let digitsOnly = phoneNumber.filter(\.isNumber)
        let localDigits = (digitsOnly.count == 11 && digitsOnly.hasPrefix("1"))
            ? String(digitsOnly.dropFirst())
            : digitsOnly
        return "\(localDigits)@\(carrier.gatewayDomain)"
    }
}

final class EmergencyContactsManager: ObservableObject {
    static let shared = EmergencyContactsManager()

    @Published var contacts: [EmergencyContact] = []
    private let storageKey = "emergencyContacts"

    private init() { load() }

    var sortedContacts: [EmergencyContact] {
        let primary   = contacts.filter { $0.priority == .primary }
        let secondary = contacts.filter { $0.priority == .secondary }
        let rest      = contacts.filter { $0.priority == .none }
                                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return primary + secondary + rest
    }

    // MARK: - Atlas helpers

    private func pushIfLoggedIn() {
        Task { @MainActor in
            guard let uid = AuthManager.shared.userId else { return }
            await pushToAtlas(userId: uid)
        }
    }

    @MainActor
    func pushToAtlas(userId: String) async {
        do {
            try await AtlasClient.shared.deleteMany(collection: "contacts",
                                                     filter: ["userId": userId])
            let docs = contacts.map { $0.atlasDoc(userId: userId) }
            try await AtlasClient.shared.insertMany(collection: "contacts", documents: docs)
        } catch {
            print("[Atlas] pushContacts error: \(error.localizedDescription)")
        }
    }

    @MainActor
    func pullFromAtlas(userId: String) async {
        do {
            let docs = try await AtlasClient.shared.find(collection: "contacts",
                                                          filter: ["userId": userId])
            let fetched = docs.compactMap { EmergencyContact(atlasDoc: $0) }
            if fetched.isEmpty {
                await pushToAtlas(userId: userId)
            } else {
                contacts = fetched
                if let data = try? JSONEncoder().encode(contacts) {
                    UserDefaults.standard.set(data, forKey: storageKey)
                }
            }
        } catch {
            print("[Atlas] pullContacts error: \(error.localizedDescription)")
        }
    }

    // MARK: - Mutations

    func add(
        name: String,
        phoneNumber: String,
        carrier: Carrier,
        priority: ContactPriority = .none,
        bumpExistingPrimaryToSecondary: Bool = false
    ) {
        if priority == .primary && bumpExistingPrimaryToSecondary {
            for i in contacts.indices where contacts[i].priority == .secondary {
                contacts[i].priority = .none
            }
            for i in contacts.indices where contacts[i].priority == .primary {
                contacts[i].priority = .secondary
            }
        } else if priority != .none {
            for i in contacts.indices where contacts[i].priority == priority {
                contacts[i].priority = .none
            }
        }
        contacts.append(EmergencyContact(id: UUID(), name: name, phoneNumber: phoneNumber,
                                         carrier: carrier, priority: priority))
        save()
        pushIfLoggedIn()
    }

    func remove(at offsets: IndexSet) {
        contacts.remove(atOffsets: offsets)
        save()
        pushIfLoggedIn()
    }

    func update(
        id: UUID,
        name: String,
        phoneNumber: String,
        carrier: Carrier,
        priority: ContactPriority,
        bumpExistingPrimaryToSecondary: Bool = false
    ) {
        if priority == .primary && bumpExistingPrimaryToSecondary {
            for i in contacts.indices where contacts[i].priority == .secondary && contacts[i].id != id {
                contacts[i].priority = .none
            }
            for i in contacts.indices where contacts[i].priority == .primary && contacts[i].id != id {
                contacts[i].priority = .secondary
            }
        } else if priority != .none {
            for i in contacts.indices where contacts[i].priority == priority && contacts[i].id != id {
                contacts[i].priority = .none
            }
        }
        if let i = contacts.firstIndex(where: { $0.id == id }) {
            contacts[i].name        = name
            contacts[i].phoneNumber = phoneNumber
            contacts[i].carrier     = carrier
            contacts[i].priority    = priority
        }
        save()
        pushIfLoggedIn()
    }

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
        pushIfLoggedIn()
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

// MARK: - Atlas serialization

extension EmergencyContact {
    func atlasDoc(userId: String) -> [String: Any] {
        ["userId": userId, "id": id.uuidString,
         "name": name, "phoneNumber": phoneNumber,
         "carrier": carrier.rawValue,
         "priority": priority.rawValue]
    }

    init?(atlasDoc doc: [String: Any]) {
        guard let idStr = doc["id"] as? String,
              let id    = UUID(uuidString: idStr),
              let name  = doc["name"] as? String,
              let phone = doc["phoneNumber"] as? String else { return nil }
        let carrier  = Carrier(rawValue: doc["carrier"] as? String ?? "") ?? .bell
        let priority = ContactPriority(rawValue: doc["priority"] as? String ?? "") ?? .none
        self.init(id: id, name: name, phoneNumber: phone, carrier: carrier, priority: priority)
    }
}
