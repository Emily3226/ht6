 private var updateTask: Task<Void, Never>?

    /// Sends the initial SOS alert automatically (no user interaction) by
    /// emailing each contact's carrier SMS gateway address -- e.g.
    /// "6135551234@txt.bell.ca" -- which the carrier delivers as a text.
    /// Delivery goes through our own backend (`/api/send-sos`), which relays
    /// via Gmail SMTP using an app password. That sidesteps a transactional
    /// email API's domain-verification requirement (we're not claiming to
    /// own a domain, we're authenticating as a real Gmail mailbox) and it
    /// sidesteps needing a full SMS-provider account (Twilio etc.), whose
    /// trial tiers require pre-verifying every recipient number, which
    /// defeats the point of an SOS that must reach *any* contact a user adds.
    func sendEmergencyAlert(
        to contacts: [EmergencyContact],
        location: CLLocation,
        backendURL: String,
        backendAPIKey: String
    ) async throws {
        try await sendLocationText(
            to: contacts,
            location: location,
            backendURL: backendURL,
            backendAPIKey: backendAPIKey,
            isFollowUp: false
        )
    }

    /// Starts resending a fresh location text every `interval` seconds so
    /// contacts effectively get a "live" trail of updates rather than one
    /// static pin from the moment SOS fired. Best-effort -- a failed send
    /// on one cycle doesn't stop the loop, it just tries again next time.
    /// Call `stopLiveUpdates()` when the SOS is cancelled or resolved.
    func startLiveUpdates(
        to contacts: [EmergencyContact],
        backendURL: String,
        backendAPIKey: String,
        interval: TimeInterval = 90
    ) {
        updateTask?.cancel()
        updateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                if let location = try? await self.requestLocation() {
                    try? await self.sendLocationText(
                        to: contacts,
                        location: location,
                        backendURL: backendURL,
                        backendAPIKey: backendAPIKey,
                        isFollowUp: true
                    )
                }
            }
        }
    }

    func stopLiveUpdates() {
        updateTask?.cancel()
        updateTask = nil
    }

    private func sendLocationText(
        to contacts: [EmergencyContact],
        location: CLLocation,
        backendURL: String,
        backendAPIKey: String,
        isFollowUp: Bool
    ) async throws {
        guard !backendURL.isEmpty, !backendAPIKey.isEmpty else {
            throw SOSError.missingEmailCredentials
        }
        guard !contacts.isEmpty else {
            throw SOSError.noEmergencyContacts
        }

        let locationLink = "https://maps.apple.com/?ll=\(location.coordinate.latitude),\(location.coordinate.longitude)"
        let message = isFollowUp
            ? "Location update: \(locationLink)"
            : "I need help. My location: \(locationLink)"

        try await sendGatewayEmail(
            to: contacts.map(\.smsGatewayAddress),
            body: message,
            backendURL: backendURL,
            backendAPIKey: backendAPIKey
        )
    }

    private func sendGatewayEmail(
        to: [String], body: String, backendURL: String, backendAPIKey: String
    ) async throws {
        guard let url = URL(string: "\(backendURL)/api/send-sos") else {
            throw SOSError.emailRequestFailed(status: 0, message: "Invalid backend URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(backendAPIKey, forHTTPHeaderField: "api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Carrier SMS gateways generally render the email's plain-text body
        // (and often ignore/strip the subject), so keep this minimal --
        // no HTML, no signature, just the alert text.
        let payload: [String: Any] = [
            "to": to,
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
            return "SOS alerts aren't configured yet -- add your backend URL and API key in Config.swift."
        case .noEmergencyContacts:
            return "No emergency contacts are saved. Add at least one, with their carrier, in the Safety tab."
        case .emailRequestFailed(let status, let message):
            return "Couldn't send the SOS alert (status \(status)): \(message)"
        }
    }
}