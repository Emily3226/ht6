import Foundation
import CoreLocation

final class SOSManager: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var locationContinuation: CheckedContinuation<CLLocation, Error>?
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?

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

    /// Sends the SOS alert automatically (no user interaction) by emailing
    /// each contact's carrier SMS gateway address -- e.g.
    /// "6135551234@txt.bell.ca" -- which the carrier delivers as a text.
    /// This sidesteps needing a full SMS-provider account (Twilio etc.),
    /// whose trial tiers require pre-verifying every recipient number,
    /// which defeats the point of an SOS that must reach *any* contact
    /// a user adds. We only need an easy-to-get transactional email API key.
    func sendEmergencyAlert(
        to contacts: [EmergencyContact],
        location: CLLocation,
        resendAPIKey: String,
        fromEmail: String
    ) async throws {
        guard !resendAPIKey.isEmpty, !fromEmail.isEmpty else {
            throw SOSError.missingEmailCredentials
        }
        guard !contacts.isEmpty else {
            throw SOSError.noEmergencyContacts
        }

        let locationLink = "https://maps.apple.com/?ll=\(location.coordinate.latitude),\(location.coordinate.longitude)"
        let message = "I need help. My location: \(locationLink)"

        try await withThrowingTaskGroup(of: Void.self) { group in
            for contact in contacts {
                group.addTask {
                    try await self.sendGatewayEmail(
                        to: contact.smsGatewayAddress,
                        body: message,
                        resendAPIKey: resendAPIKey,
                        fromEmail: fromEmail
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    private func sendGatewayEmail(
        to: String, body: String, resendAPIKey: String, fromEmail: String
    ) async throws {
        let url = URL(string: "https://api.resend.com/emails")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(resendAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Carrier SMS gateways generally render the email's plain-text body
        // (and often ignore/strip the subject), so keep this minimal --
        // no HTML, no signature, just the alert text.
        let payload: [String: Any] = [
            "from": fromEmail,
            "to": [to],
            "subject": "SOS",
            "text": body
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown error"
            throw SOSError.emailRequestFailed(status: http.statusCode, message: bodyText)
        }
    }
}

enum SOSError: LocalizedError {
    case locationPermissionDenied
    case missingEmailCredentials
    case noEmergencyContacts
    case emailRequestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .locationPermissionDenied:
            return "Location access is off, so we can't include your position in the SOS message. Enable it in Settings > Privacy > Location Services."
        case .missingEmailCredentials:
            return "SOS alerts aren't configured yet -- add your Resend API key and from-address in Config.swift."
        case .noEmergencyContacts:
            return "No emergency contacts are saved. Add at least one, with their carrier, in the Safety tab."
        case .emailRequestFailed(let status, let message):
            return "Couldn't send the SOS alert (status \(status)): \(message)"
        }
    }
}