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
    /// geolocation snapshot to it later once the location fix comes back.
    @discardableResult
    func log(hazardType: String, direction: String, urgency: String) -> UUID {
        let incident = Incident(
            id: UUID(), date: Date(),
            hazardType: hazardType, direction: direction, urgency: urgency,
            latitude: nil, longitude: nil
        )
        incidents.insert(incident, at: 0)
        save()
        Task { @MainActor in
            guard let uid = AuthManager.shared.userId else { return }
            try? await AtlasClient.shared.insertOne(
                collection: "incidents",
                document: incident.atlasDoc(userId: uid)
            )
        }
        return incident.id
    }

    /// Attaches a geolocation snapshot to a previously logged incident.
    func attachLocation(_ location: CLLocation, toIncidentWithId id: UUID) {
        guard let index = incidents.firstIndex(where: { $0.id == id }) else { return }
        incidents[index].latitude = location.coordinate.latitude
        incidents[index].longitude = location.coordinate.longitude
        save()
        let updated = incidents[index]
        Task { @MainActor in
            guard let uid = AuthManager.shared.userId else { return }
            try? await AtlasClient.shared.replaceOne(
                collection: "incidents",
                filter: ["userId": uid, "id": updated.id.uuidString],
                replacement: updated.atlasDoc(userId: uid)
            )
        }
    }

    func remove(at offsets: IndexSet) {
        let removed = offsets.map { incidents[$0] }
        incidents.remove(atOffsets: offsets)
        save()
        Task { @MainActor in
            guard let uid = AuthManager.shared.userId else { return }
            for incident in removed {
                try? await AtlasClient.shared.deleteOne(
                    collection: "incidents",
                    filter: ["userId": uid, "id": incident.id.uuidString]
                )
            }
        }
    }

    // MARK: - Atlas sync

    /// Aggregated stats for the History tab's Insights card, computed by a
    /// MongoDB $facet aggregation pipeline on the Atlas cluster (not by
    /// scanning documents client-side).
    struct Insights {
        var total: Int
        var highCount: Int
        var mediumCount: Int
        var lowCount: Int
        var topHazards: [(type: String, count: Int)]
    }

    @MainActor
    func fetchInsights(userId: String) async -> Insights? {
        let pipeline: [[String: Any]] = [
            ["$match": ["userId": userId]],
            ["$facet": [
                "byUrgency": [
                    ["$group": ["_id": "$urgency", "count": ["$sum": 1]]]
                ],
                "topHazards": [
                    ["$group": ["_id": "$hazardType", "count": ["$sum": 1]]],
                    ["$sort": ["count": -1]],
                    ["$limit": 3]
                ],
                "total": [["$count": "n"]]
            ]]
        ]
        guard let facet = try? await AtlasClient.shared.aggregate(
            collection: "incidents", pipeline: pipeline
        ).first else { return nil }

        var insights = Insights(total: 0, highCount: 0, mediumCount: 0,
                                lowCount: 0, topHazards: [])
        insights.total = ((facet["total"] as? [[String: Any]])?.first?["n"] as? Int) ?? 0
        for bucket in facet["byUrgency"] as? [[String: Any]] ?? [] {
            let count = bucket["count"] as? Int ?? 0
            switch bucket["_id"] as? String {
            case "high":   insights.highCount   = count
            case "medium": insights.mediumCount = count
            default:       insights.lowCount   += count
            }
        }
        insights.topHazards = (facet["topHazards"] as? [[String: Any]] ?? []).compactMap {
            guard let type = $0["_id"] as? String,
                  let count = $0["count"] as? Int else { return nil }
            return (type, count)
        }
        return insights
    }

    /// How many times this user has already hit the same hazard type within
    /// ~40 m of this spot — a MongoDB $geoNear query against the 2dsphere
    /// index on incidents.location. Powers the spoken "you've encountered
    /// this here before" callback.
    @MainActor
    func nearbyRepeatCount(hazardType: String,
                           latitude: Double, longitude: Double,
                           excluding id: UUID, userId: String) async -> Int {
        let pipeline: [[String: Any]] = [
            ["$geoNear": [
                "near": ["type": "Point", "coordinates": [longitude, latitude]],
                "distanceField": "distanceMeters",
                "maxDistance": 40,
                "spherical": true,
                "query": [
                    "userId": userId,
                    "hazardType": hazardType,
                    "id": ["$ne": id.uuidString]
                ]
            ]],
            ["$count": "n"]
        ]
        let docs = (try? await AtlasClient.shared.aggregate(
            collection: "incidents", pipeline: pipeline)) ?? []
        return docs.first?["n"] as? Int ?? 0
    }

    @MainActor
    func pullFromAtlas(userId: String) async {
        do {
            let docs = try await AtlasClient.shared.find(
                collection: "incidents",
                filter: ["userId": userId],
                sort: ["date": -1]
            )
            let fetched = docs.compactMap { Incident(atlasDoc: $0) }
            let existingIds = Set(incidents.map(\.id))
            let newOnes = fetched.filter { !existingIds.contains($0.id) }
            guard !newOnes.isEmpty else { return }
            incidents = (incidents + newOnes).sorted { $0.date > $1.date }
            save()
        } catch {
            print("[Atlas] pullIncidents error: \(error.localizedDescription)")
        }
    }

    // MARK: - Local persistence

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

// MARK: - Atlas serialization

extension Incident {
    func atlasDoc(userId: String) -> [String: Any] {
        var doc: [String: Any] = [
            "userId":     userId,
            "id":         id.uuidString,
            "date":       date.timeIntervalSince1970,
            "hazardType": hazardType,
            "direction":  direction,
            "urgency":    urgency
        ]
        if let lat = latitude  { doc["latitude"]  = lat }
        if let lon = longitude { doc["longitude"] = lon }
        // GeoJSON copy of the coordinates so Atlas's 2dsphere index can
        // serve $geoNear queries (note: GeoJSON order is [lon, lat]).
        if let lat = latitude, let lon = longitude {
            doc["location"] = ["type": "Point", "coordinates": [lon, lat]]
        }
        return doc
    }

    init?(atlasDoc doc: [String: Any]) {
        guard let idStr      = doc["id"] as? String,
              let id         = UUID(uuidString: idStr),
              let ts         = doc["date"] as? Double,
              let hazardType = doc["hazardType"] as? String,
              let direction  = doc["direction"] as? String,
              let urgency    = doc["urgency"] as? String else { return nil }
        self.id         = id
        self.date       = Date(timeIntervalSince1970: ts)
        self.hazardType = hazardType
        self.direction  = direction
        self.urgency    = urgency
        self.latitude   = doc["latitude"] as? Double
        self.longitude  = doc["longitude"] as? Double
    }
}
