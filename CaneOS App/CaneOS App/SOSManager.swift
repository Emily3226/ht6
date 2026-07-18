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

    /// Sends the SOS alert automatically (no user interaction) by asking the
    /// Vercel backend to email each contact's carrier SMS gateway address
    /// -- e.g. "6135551234@txt.bell.ca" -- which the carrier delivers as a
    /// text. This sidesteps needing a full SMS-provider account (Twilio
    /// etc.), whose trial tiers require pre-verifying every recipient
    /// number, which defeats the point of an SOS that must reach *any*
    /// contact a user adds. The Resend API key itself now lives only in
    /// Vercel's environment (see vercel-backend/), not in this app.
    func sendEmergencyAlert(
        to contacts: [EmergencyContact],
        location: CLLocation,
        hazardType: String = "manual_sos",
        direction: String = "-",
        urgency: String = "high"
    ) async throws {
        guard !contacts.isEmpty else {
            throw SOSError.noEmergencyContacts
        }
        do {
            try await BackendClient.shared.sendSOS(
                contactGatewayAddresses: contacts.map(\.smsGatewayAddress),
                location: location,
                hazardType: hazardType,
                direction: direction,
                urgency: urgency
            )
        } catch BackendClient.BackendError.notConfigured {
            throw SOSError.missingEmailCredentials
        } catch BackendClient.BackendError.requestFailed(let status, let message) {
            throw SOSError.emailRequestFailed(status: status, message: message)
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
            return "SOS alerts aren't configured yet -- add backendAPIBaseURL and backendAPIKey in Config.swift (see vercel-backend/README.md)."
        case .noEmergencyContacts:
            return "No emergency contacts are saved. Add at least one, with their carrier, in the Safety tab."
        case .emailRequestFailed(let status, let message):
            return "Couldn't send the SOS alert (status \(status)): \(message)"
        }
    }
}