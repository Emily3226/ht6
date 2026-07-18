import Foundation

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

    func add(name: String, phoneNumber: String, carrier: Carrier) {
        contacts.append(EmergencyContact(id: UUID(), name: name, phoneNumber: phoneNumber, carrier: carrier))
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