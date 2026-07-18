import Foundation
import CoreLocation

final class SOSManager: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

    // Identifies the active SOS event in Atlas so live-update writes go to
    // the same document (via updateOne) instead of creating a new one every
    // ~90s. Set by sendEmergencyAlert, cleared by stopLiveUpdates.
    private var activeEventId: String?
    private var liveUpdateTask: Task<Void, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Fetches the current location, first waiting for the user to actually
    /// respond to the permission dialog if authorization hasn't been decided
    /// yet, rather than racing `requestLocation()` against the system prompt.
    func requestLocation() async throws -> CLLocation {
        let status = locationManager.authorizationStatus

        let resolvedStatus: CLAuthorizationStatus
        if status == .notDetermined {
            resolvedStatus = await withCheckedContinuation { continuation in
                self.authContinuation = continuation
                locationManager.requestWhenInUseAuthorization()
            }
        } else {
            resolvedStatus = status
        }

        guard resolvedStatus == .authorizedWhenInUse || resolvedStatus == .authorizedAlways else {
            throw SOSError.locationPermissionDenied
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard let authContinuation else { return }
        let status = manager.authorizationStatus
        if status != .notDetermined {
            self.authContinuation = nil
            authContinuation.resume(returning: status)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            locationContinuation?.resume(returning: location)
            locationContinuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
    }

    // MARK: - SOS

    /// Writes an SOS event document to Atlas via the Data API (insertOne).
    /// An Atlas Trigger/Function on the `sos_events` collection is
    /// responsible for actually notifying contacts (e.g. emailing each
    /// contact's carrier SMS gateway through Resend) -- this call's job is
    /// only to get the alert + location into Atlas as fast as possible.
    /// Keeping the Resend key server-side (in the Atlas Function, not here)
    /// is the whole point of going through the Data API instead of calling
    /// Resend directly from the app.
    func sendEmergencyAlert(
        to contacts: [EmergencyContact],
        location: CLLocation,
        backendURL: String,
        backendAPIKey: String
    ) async throws {
        guard !backendURL.isEmpty, !backendAPIKey.isEmpty else {
            throw SOSError.missingBackendCredentials
        }
        guard !contacts.isEmpty else {
            throw SOSError.noEmergencyContacts
        }

        let document: [String: Any] = [
            "contacts": contacts.map { contact in
                [
                    "name": contact.name,
                    "smsGatewayAddress": contact.smsGatewayAddress,
                ]
            },
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "status": "active",
            "createdAt": ["$date": ["$numberLong": String(Int(Date().timeIntervalSince1970 * 1000))]],
        ]

        let result = try await dataAPIRequest(
            action: "insertOne",
            backendURL: backendURL,
            backendAPIKey: backendAPIKey,
            body: ["collection": "sos_events", "document": document]
        )

        // Atlas Data API's insertOne response looks like {"insertedId": "..."}
        guard let insertedId = (result["insertedId"] as? String) else {
            throw SOSError.backendRequestFailed(status: 200, message: "Missing insertedId in response")
        }
        activeEventId = insertedId
    }

    /// Keeps contacts updated with a fresh location roughly every 90
    /// seconds for as long as the SOS stays active, by patching the same
    /// Atlas document `sendEmergencyAlert` created (rather than inserting a
    /// new one each time). Call `stopLiveUpdates()` when the SOS is
    /// cancelled or resolved.
    func startLiveUpdates(
        to contacts: [EmergencyContact],
        backendURL: String,
        backendAPIKey: String,
        interval: TimeInterval = 90
    ) {
        guard liveUpdateTask == nil else { return }
        liveUpdateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard let eventId = self.activeEventId,
                      let location = try? await self.requestLocation() else { continue }
                try? await self.pushLiveUpdate(
                    eventId: eventId,
                    location: location,
                    backendURL: backendURL,
                    backendAPIKey: backendAPIKey
                )
            }
        }
    }

    /// Stops the recurring live-location writes and clears the active SOS
    /// event id. Safe to call even if no live updates are running (e.g. from
    /// `cancelSOS()` on every cancel, not just ones that actually started
    /// live tracking).
    func stopLiveUpdates() {
        liveUpdateTask?.cancel()
        liveUpdateTask = nil
        activeEventId = nil
    }

    private func pushLiveUpdate(
        eventId: String,
        location: CLLocation,
        backendURL: String,
        backendAPIKey: String
    ) async throws {
        _ = try await dataAPIRequest(
            action: "updateOne",
            backendURL: backendURL,
            backendAPIKey: backendAPIKey,
            body: [
                "collection": "sos_events",
                "filter": ["_id": ["$oid": eventId]],
                "update": [
                    "$set": [
                        "latitude": location.coordinate.latitude,
                        "longitude": location.coordinate.longitude,
                        "updatedAt": ["$date": ["$numberLong": String(Int(Date().timeIntervalSince1970 * 1000))]],
                    ]
                ],
            ]
        )
    }

    // MARK: - Atlas Data API

    /// Thin wrapper around the Atlas Data API's action endpoints
    /// (https://<region>.data.mongodb-api.com/app/<app-id>/endpoint/data/v1/action/<action>).
    /// `backendURL` is that base URL up through `.../data/v1`; `dataSource`
    /// and `database` are filled in here since every call in this file
    /// targets the same cluster/db.
    private func dataAPIRequest(
        action: String,
        backendURL: String,
        backendAPIKey: String,
        body: [String: Any]
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(backendURL)/action/\(action)") else {
            throw SOSError.backendRequestFailed(status: 0, message: "Invalid backend URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/ejson", forHTTPHeaderField: "Accept")
        request.setValue(backendAPIKey, forHTTPHeaderField: "apiKey")

        var fullBody = body
        fullBody["dataSource"] = "Cluster0"
        fullBody["database"] = "caneos"
        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw SOSError.backendRequestFailed(status: status, message: message)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SOSError.backendRequestFailed(status: http.statusCode, message: "Non-JSON response")
        }
        return json
    }
}

enum SOSError: LocalizedError {
    case locationPermissionDenied
    case missingBackendCredentials
    case noEmergencyContacts
    case backendRequestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .locationPermissionDenied:
            return "Location access is off, so we can't include your position in the SOS message. Enable it in Settings > Privacy > Location Services."
        case .missingBackendCredentials:
            return "SOS alerts aren't configured yet -- add atlasDataAPIURL and atlasAPIKey in Config.swift."
        case .noEmergencyContacts:
            return "No emergency contacts are saved. Add at least one, with their carrier, in the Safety tab."
        case .backendRequestFailed(let status, let message):
            return "Couldn't send the SOS alert (status \(status)): \(message)"
        }
    }
}