import Foundation
import Combine
import SwiftUI

/// Priority level for an emergency contact -- primary and secondary are each
/// unique (only one contact can hold each at a time), used to order SOS
/// alerts and to highlight contacts in the Safety tab.
/// NOTE: if this enum already exists in another file in your project (it's
/// referenced throughout ContentView.swift but wasn't included in either
/// side of the conflict), delete this definition here to avoid a duplicate.
enum ContactPriority: String, Codable {
    case none, primary, secondary
}

/// Mobile carrier, used to build an email-to-SMS gateway address
/// (e.g. "6135551234@txt.bell.ca"). We route SOS alerts through the
/// carrier's email gateway instead of a direct SMS API (see SOSManager),
/// so we need to know each contact's carrier to build the right address.
enum Carrier: String, Codable, CaseIterable, Identifiable {
    // Canadian carriers
    case bell, telus, rogers, fido, koodo, virginPlus, freedom, videotron
    // US carriers (in case a contact is in the US)
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

    /// The email-to-SMS gateway domain for this carrier. Sending an email to
    /// "[10-digit number]@[this domain]" gets delivered as a text message.
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

    /// The email address that, when sent an email, gets delivered to this
    /// contact's phone as a text message via their carrier's SMS gateway.
    var smsGatewayAddress: String {
        let digitsOnly = phoneNumber.filter(\.isNumber)
        // Most gateways expect the bare 10-digit number, without a leading
        // country code -- strip a leading "1" if present (e.g. from +1...).
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

    /// Primary first, secondary second, then the rest sorted A–Z.
    var sortedContacts: [EmergencyContact] {
        let primary   = contacts.filter { $0.priority == .primary }
        let secondary = contacts.filter { $0.priority == .secondary }
        let rest      = contacts.filter { $0.priority == .none }
                                .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        return primary + secondary + rest
    }

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
        contacts.append(EmergencyContact(id: UUID(), name: name, phoneNumber: phoneNumber, carrier: carrier, priority: priority))
        save()
    }

    func remove(at offsets: IndexSet) {
        contacts.remove(atOffsets: offsets)
        save()
    }

    /// Edit an existing contact. Pass `bumpExistingPrimaryToSecondary: true` to move
    /// the current primary to secondary instead of clearing it when promoting a new primary.
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

        // Best-effort remote sync -- UserDefaults above remains the source
        // of truth locally, so this never blocks add/edit/remove even if
        // the backend is unreachable or unconfigured.
        let contactsSnapshot = contacts
        Task {
            try? await BackendClient.shared.syncContacts(contactsSnapshot)
        }
        Task { @MainActor in
            guard let uid = AuthManager.shared.userId else { return }
            await pushToAtlas(userId: uid)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([EmergencyContact].self, from: data) {
            contacts = saved
        }
    }

    // MARK: - Atlas sync (per-user, Auth0-scoped; used by AuthManager's
    // cross-device sync on login/restore)

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