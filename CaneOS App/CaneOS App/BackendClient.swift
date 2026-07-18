import Foundation
import CoreLocation

/// Talks to the Vercel proxy in `vercel-backend/` instead of Mongo or
/// Resend directly, so those credentials never ship in the app bundle.
/// Requires `Config.backendAPIBaseURL` and `Config.backendAPIKey` to be set
/// (see vercel-backend/README.md for where those values come from); if
/// either is empty, every call below throws `.notConfigured` and callers
/// fall back to local-only behavior.
final class BackendClient {
    static let shared = BackendClient()

    enum BackendError: LocalizedError {
        case notConfigured
        case requestFailed(status: Int, message: String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Backend sync isn't configured -- add backendAPIBaseURL and backendAPIKey in Config.swift."
            case .requestFailed(let status, let message):
                return "Backend request failed (status \(status)): \(message)"
            }
        }
    }

    private var isConfigured: Bool {
        !Config.backendAPIBaseURL.isEmpty && !Config.backendAPIKey.isEmpty
    }

    private func request(path: String, method: String, body: [String: Any]? = nil) async throws -> Data {
        guard isConfigured else { throw BackendError.notConfigured }
        let url = URL(string: Config.backendAPIBaseURL + path)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(Config.backendAPIKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw BackendError.requestFailed(status: http.statusCode, message: message)
        }
        return data
    }

    /// Sends the SOS alert (Resend email-to-SMS-gateway messages) and logs
    /// the incident, both server-side. Replaces the old direct-to-Resend
    /// call that used to live in SOSManager.
    func sendSOS(
        contactGatewayAddresses: [String],
        location: CLLocation,
        hazardType: String,
        direction: String,
        urgency: String
    ) async throws {
        _ = try await request(path: "/api/sos", method: "POST", body: [
            "contacts": contactGatewayAddresses,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "hazardType": hazardType,
            "direction": direction,
            "urgency": urgency,
        ])
    }

    /// Best-effort push of a locally-logged incident. Called from
    /// IncidentStore after every local save; failures are swallowed by the
    /// caller since local storage (UserDefaults) remains the source of
    /// truth the app can always read from, even offline or unconfigured.
    func logIncident(_ incident: Incident) async throws {
        _ = try await request(path: "/api/incidents", method: "POST", body: [
            "hazardType": incident.hazardType,
            "direction": incident.direction,
            "urgency": incident.urgency,
            "latitude": incident.latitude as Any,
            "longitude": incident.longitude as Any,
        ])
    }

    /// Full-list sync: replaces the whole `contacts` collection in Mongo
    /// with what's currently in the app. Simplest correct option for a
    /// single-device app -- see vercel-backend/api/contacts.js for why.
    func syncContacts(_ contacts: [EmergencyContact]) async throws {
        let payload = contacts.map { contact -> [String: Any] in
            [
                "id": contact.id.uuidString,
                "name": contact.name,
                "phoneNumber": contact.phoneNumber,
                "carrier": contact.carrier.rawValue,
                "priority": contact.priority.rawValue,
            ]
        }
        _ = try await request(path: "/api/contacts", method: "POST", body: ["contacts": payload])
    }
}