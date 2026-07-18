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
    /// yet. Previously this fired `requestLocation()` immediately after
    /// `requestWhenInUseAuthorization()`, which raced the system prompt --
    /// on a fresh install the location request would fail instantly with
    /// "not authorized" before the person had a chance to tap Allow.
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

    // Sends via Twilio so this fires automatically -- MFMessageComposeViewController
    // requires the user to tap "Send" themselves, which defeats the point of an SOS.
    func sendEmergencyAlert(
        to contacts: [EmergencyContact],
        location: CLLocation,
        accountSid: String,
        authToken: String,
        fromNumber: String
    ) async throws {
        guard !accountSid.isEmpty, !authToken.isEmpty, !fromNumber.isEmpty else {
            throw SOSError.missingTwilioCredentials
        }
        guard !contacts.isEmpty else {
            throw SOSError.noEmergencyContacts
        }

        let locationLink = "https://maps.apple.com/?ll=\(location.coordinate.latitude),\(location.coordinate.longitude)"
        let message = "I need help. My location: \(locationLink)"

        try await withThrowingTaskGroup(of: Void.self) { group in
            for contact in contacts {
                group.addTask {
                    try await self.sendTwilioSMS(
                        to: contact.phoneNumber,
                        body: message,
                        accountSid: accountSid,
                        authToken: authToken,
                        fromNumber: fromNumber
                    )
                }
            }
            try await group.waitForAll()
        }
    }

    private func sendTwilioSMS(
        to: String, body: String,
        accountSid: String, authToken: String, fromNumber: String
    ) async throws {
        let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSid)/Messages.json")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let credentials = "\(accountSid):\(authToken)".data(using: .utf8)!.base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        func encode(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        let bodyString = "To=\(encode(to))&From=\(encode(fromNumber))&Body=\(encode(body))"
        request.httpBody = bodyString.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? "unknown error"
            throw SOSError.twilioRequestFailed(status: http.statusCode, message: bodyText)
        }
    }
}

enum SOSError: LocalizedError {
    case locationPermissionDenied
    case missingTwilioCredentials
    case noEmergencyContacts
    case twilioRequestFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .locationPermissionDenied:
            return "Location access is off, so we can't include your position in the SOS message. Enable it in Settings > Privacy > Location Services."
        case .missingTwilioCredentials:
            return "SOS texting isn't configured yet -- add your Twilio credentials in Config.swift."
        case .noEmergencyContacts:
            return "No emergency contacts are saved. Add at least one in the Safety tab."
        case .twilioRequestFailed(let status, let message):
            return "Twilio couldn't send the SOS message (status \(status)): \(message)"
        }
    }
}