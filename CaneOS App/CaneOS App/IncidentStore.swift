import Foundation
import SwiftUI
import Combine

struct Incident: Identifiable, Codable {
    let id: UUID
    let date: Date
    let hazardType: String
    let direction: String
    let urgency: String
}

final class IncidentStore: ObservableObject {
    static let shared = IncidentStore()
    @Published var incidents: [Incident] = []
    private let key = "incidentLog"

    private init() { load() }

    func log(hazardType: String, direction: String, urgency: String) {
        let incident = Incident(
            id: UUID(), date: Date(),
            hazardType: hazardType, direction: direction, urgency: urgency
        )
        incidents.insert(incident, at: 0)
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
