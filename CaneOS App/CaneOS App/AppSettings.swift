import Foundation
import Combine

/// Which of the two app experiences this account uses. Chosen during
/// account setup and switchable anytime from Settings.
enum UserRole: String, CaseIterable, Identifiable {
    /// The visually impaired cane user — full device settings, location
    /// sharing toggle.
    case primary
    /// A sighted loved one — same app minus device settings, plus a live
    /// map of the primary user's location.
    case support

    var id: String { rawValue }

    var label: String {
        switch self {
        case .primary: return "Visually Impaired"
        case .support: return "Support Partner"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum HapticIntensity: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum SensitivityLevel: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    @Published var hapticIntensity: HapticIntensity {
        didSet {
            UserDefaults.standard.set(hapticIntensity.rawValue, forKey: "hapticIntensity")
            pushIfLoggedIn()
        }
    }
    @Published var sensitivityLevel: SensitivityLevel {
        didSet {
            UserDefaults.standard.set(sensitivityLevel.rawValue, forKey: "sensitivityLevel")
            pushIfLoggedIn()
        }
    }
    @Published var audioEnabled: Bool {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "audioEnabled")
            pushIfLoggedIn()
        }
    }

    /// nil until the user picks a role during account setup.
    @Published var userRole: UserRole? {
        didSet {
            UserDefaults.standard.set(userRole?.rawValue, forKey: "userRole")
            pushIfLoggedIn()
        }
    }

    /// Primary role: whether live location is being shared with the
    /// support partner.
    @Published var locationSharingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(locationSharingEnabled, forKey: "locationSharingEnabled")
            pushIfLoggedIn()
        }
    }

    /// Support role: the share code of the primary user being followed.
    @Published var followCode: String {
        didSet {
            UserDefaults.standard.set(followCode, forKey: "followCode")
            pushIfLoggedIn()
        }
    }

    /// Primary role: the code a support partner enters to follow this user's
    /// location. Generated once, lazily.
    @Published private(set) var shareCode: String {
        didSet {
            UserDefaults.standard.set(shareCode, forKey: "shareCode")
        }
    }

    /// Returns the share code (always non-empty; generated at init).
    func ensureShareCode() -> String { shareCode }

    /// Set to true while applying values pulled from Atlas so the didSet
    /// observers don't immediately push those same values back up.
    private var isLoadingFromAtlas = false

    private init() {
        hapticIntensity  = HapticIntensity(rawValue: UserDefaults.standard.string(forKey: "hapticIntensity") ?? "") ?? .medium
        sensitivityLevel = SensitivityLevel(rawValue: UserDefaults.standard.string(forKey: "sensitivityLevel") ?? "") ?? .medium
        audioEnabled     = UserDefaults.standard.object(forKey: "audioEnabled") as? Bool ?? true
        userRole         = UserRole(rawValue: UserDefaults.standard.string(forKey: "userRole") ?? "")
        locationSharingEnabled = UserDefaults.standard.bool(forKey: "locationSharingEnabled")
        followCode       = UserDefaults.standard.string(forKey: "followCode") ?? ""
        let storedCode   = UserDefaults.standard.string(forKey: "shareCode") ?? ""
        // Generate the share code up front (cheap, and setting it here skips
        // didSet) so views can display it without mutating state mid-render.
        // A cloud pull replaces it with the account's real code if one exists.
        shareCode = storedCode.isEmpty ? Self.generateShareCode() : storedCode
        if storedCode.isEmpty {
            UserDefaults.standard.set(shareCode, forKey: "shareCode")
        }
    }

    private static func generateShareCode() -> String {
        // Unambiguous alphabet: no 0/O or 1/I, so the code survives being
        // read out loud.
        let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        return String((0..<6).map { _ in alphabet.randomElement()! })
    }

    // MARK: - Atlas sync

    private func pushIfLoggedIn() {
        guard !isLoadingFromAtlas else { return }
        Task { @MainActor in
            guard let uid = AuthManager.shared.userId else { return }
            await pushToAtlas(userId: uid)
        }
    }

    @MainActor
    func pushToAtlas(userId: String) async {
        var doc: [String: Any] = [
            "userId":           userId,
            "hapticIntensity":  hapticIntensity.rawValue,
            "sensitivityLevel": sensitivityLevel.rawValue,
            "audioEnabled":     audioEnabled,
            "locationSharingEnabled": locationSharingEnabled,
            "followCode":       followCode,
            "shareCode":        shareCode
        ]
        if let role = userRole { doc["userRole"] = role.rawValue }
        do {
            try await AtlasClient.shared.replaceOne(
                collection: "settings",
                filter: ["userId": userId],
                replacement: doc
            )
        } catch {
            print("[Atlas] pushSettings error: \(error.localizedDescription)")
        }
    }

    @MainActor
    func pullFromAtlas(userId: String) async {
        do {
            let docs = try await AtlasClient.shared.find(collection: "settings",
                                                          filter: ["userId": userId])
            guard let doc = docs.first else {
                // No cloud settings yet — seed Atlas with current local values.
                await pushToAtlas(userId: userId)
                return
            }
            isLoadingFromAtlas = true
            if let v = doc["hapticIntensity"] as? String,
               let h = HapticIntensity(rawValue: v)  { hapticIntensity  = h }
            if let v = doc["sensitivityLevel"] as? String,
               let s = SensitivityLevel(rawValue: v) { sensitivityLevel = s }
            if let a = doc["audioEnabled"] as? Bool  { audioEnabled     = a }
            if let r = doc["userRole"] as? String,
               let role = UserRole(rawValue: r)      { userRole         = role }
            if let l = doc["locationSharingEnabled"] as? Bool { locationSharingEnabled = l }
            if let f = doc["followCode"] as? String, !f.isEmpty { followCode = f }
            if let s = doc["shareCode"] as? String, !s.isEmpty  { shareCode  = s }
            isLoadingFromAtlas = false
        } catch {
            print("[Atlas] pullSettings error: \(error.localizedDescription)")
        }
    }
}
