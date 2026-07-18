import Foundation
import SwiftUI
import Combine
import CoreLocation

struct Incident: Identifiable, Codable {
    let id: UUID
    let date: Date
    let hazardType: String
    let direction: String
    let urgency: String
    /// Geolocation snapshot captured at (or shortly after) the moment the
    /// incident was logged, so History can show where it happened. Optional
    /// because location may be unavailable (permission denied, no fix yet)
    /// and older saved incidents predate this field.
    var latitude: Double?
    var longitude: Double?

    var hasLocation: Bool { latitude != nil && longitude != nil }

    var mapsURL: URL? {
        guard let latitude, let longitude else { return nil }
        return URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)")
    }
}

final class IncidentStore: ObservableObject {
    static let shared = IncidentStore()
    @Published var incidents: [Incident] = []
    private let key = "incidentLog"

    private init() { load() }

    /// Logs a new incident and returns its id so a caller can attach a
    /// geolocation snapshot to it later once the location fix comes back
    /// (location lookups are async and shouldn't block logging the event).
    @discardableResult
    func log(hazardType: String, direction: String, urgency: String) -> UUID {
        let incident = Incident(
            id: UUID(), date: Date(),
            hazardType: hazardType, direction: direction, urgency: urgency,
            latitude: nil, longitude: nil
        )
        incidents.insert(incident, at: 0)
        save()

        // Best-effort remote sync -- local UserDefaults storage above is
        // the source of truth the rest of the app reads from, so a failed
        // or unconfigured backend never blocks logging an incident locally.
        Task {
            try? await BackendClient.shared.logIncident(incident)
        }
        return incident.id
    }

    /// Attaches a geolocation snapshot to a previously logged incident.
    func attachLocation(_ location: CLLocation, toIncidentWithId id: UUID) {
        guard let index = incidents.firstIndex(where: { $0.id == id }) else { return }
        incidents[index].latitude = location.coordinate.latitude
        incidents[index].longitude = location.coordinate.longitude
        save()
    }

    func remove(at offsets: IndexSet) {
        incidents.remove(atOffsets: offsets)
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(incidents) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([Incident].self, from: data) else { return }
        incidents = saved
    }
}