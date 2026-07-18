import Foundation
import CoreLocation
import Combine

/// Publishes the primary user's live location to Atlas while sharing is on.
///
/// One document per user in the `shared_locations` collection, upserted at
/// most every `publishInterval` seconds. The support partner's map reads it
/// back by share code. Turning sharing off publishes one final document
/// with `sharing: false` so followers see "paused" instead of a stale pin.
final class LocationSharingManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationSharingManager()

    @Published private(set) var isSharing = false
    @Published private(set) var lastPublished: Date?

    private let locationManager = CLLocationManager()
    private let publishInterval: TimeInterval = 10
    private var lastPushAttempt = Date.distantPast

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        locationManager.distanceFilter = 15
    }

    func start() {
        guard !isSharing else { return }
        isSharing = true
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        locationManager.startUpdatingLocation()
    }

    func stop() {
        guard isSharing else { return }
        isSharing = false
        locationManager.stopUpdatingLocation()
        Task { await publishStopped() }
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if isSharing, status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isSharing, let location = locations.last else { return }
        guard Date().timeIntervalSince(lastPushAttempt) >= publishInterval else { return }
        lastPushAttempt = Date()
        Task { await publish(location) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationSharing] location error: \(error.localizedDescription)")
    }

    // MARK: - Atlas

    @MainActor
    private func publish(_ location: CLLocation) async {
        guard let uid = AuthManager.shared.userId else { return }
        let doc: [String: Any] = [
            "userId":    uid,
            "shareCode": AppSettings.shared.ensureShareCode(),
            "name":      AuthManager.shared.userName ?? "CaneOS user",
            "latitude":  location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "updatedAt": Date().timeIntervalSince1970,
            "sharing":   true
        ]
        do {
            try await AtlasClient.shared.replaceOne(
                collection: "shared_locations",
                filter: ["userId": uid],
                replacement: doc
            )
            lastPublished = Date()
        } catch {
            print("[LocationSharing] publish error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private func publishStopped() async {
        guard let uid = AuthManager.shared.userId else { return }
        let doc: [String: Any] = [
            "userId":    uid,
            "shareCode": AppSettings.shared.ensureShareCode(),
            "name":      AuthManager.shared.userName ?? "CaneOS user",
            "updatedAt": Date().timeIntervalSince1970,
            "sharing":   false
        ]
        try? await AtlasClient.shared.replaceOne(
            collection: "shared_locations",
            filter: ["userId": uid],
            replacement: doc
        )
    }
}
