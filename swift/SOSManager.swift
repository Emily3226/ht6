import Foundation
import CoreLocation

final class SOSManager: NSObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func requestLocation() async throws -> CLLocation {
        locationManager.requestWhenInUseAuthorization()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            locationManager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let location = locations.first {
            continuation?.resume(returning: location)
            continuation = nil
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
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

        _ = try await URLSession.shared.data(for: request)
    }
}
