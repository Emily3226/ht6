import Foundation
import Combine
import Auth0

/// Manages the Auth0 login session and triggers MongoDB Atlas cloud sync.
///
/// ── Setup checklist ──────────────────────────────────────────────────────
///
/// 1. Add Auth0.swift via Swift Package Manager:
///    File › Add Package Dependencies
///    URL: https://github.com/auth0/Auth0.swift  (pick version 2.x)
///
/// 2. Fill in Auth0.plist (already in the project) with your tenant's
///    ClientId and Domain from dash.auth0.com › Applications › your app.
///
/// 3. Xcode target › Info › URL Types → add a new entry:
///    URL Schemes: $(PRODUCT_BUNDLE_IDENTIFIER)
///
/// 4. In the Auth0 dashboard add these Allowed Callback / Logout URLs:
///    {BUNDLE_ID}://{YOUR_DOMAIN}/ios/{BUNDLE_ID}/callback
///    (replace BUNDLE_ID and YOUR_DOMAIN with your actual values)
///
/// 5. Fill in the three Atlas keys in Config.swift.
/// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isAuthenticated = false
    @Published var userId:    String?
    @Published var userName:  String?
    @Published var userEmail: String?
    @Published var isSyncing  = false

    private let credManager = CredentialsManager(authentication: Auth0.authentication())

    private init() {
        Task { await restoreSession() }
    }

    // MARK: - Auth

    func login() async {
        do {
            let creds = try await Auth0.webAuth().start()
            try credManager.store(credentials: creds)
            let profile = try await Auth0.authentication()
                .userInfo(withAccessToken: creds.accessToken)
                .start()
            applyProfile(profile)
            await syncFromCloud()
        } catch {
            print("[Auth0] login error: \(error.localizedDescription)")
        }
    }

    func logout() async {
        do {
            try await Auth0.webAuth().logout()
        } catch {
            print("[Auth0] logout error: \(error.localizedDescription)")
        }
        try? credManager.clear()
        isAuthenticated = false
        userId = nil; userName = nil; userEmail = nil
    }

    // MARK: - Cloud sync

    /// Pull all user data from Atlas (called automatically after login / session restore).
    func syncFromCloud() async {
        guard let uid = userId else { return }
        isSyncing = true
        defer { isSyncing = false }
        await EmergencyContactsManager.shared.pullFromAtlas(userId: uid)
        await AppSettings.shared.pullFromAtlas(userId: uid)
        await IncidentStore.shared.pullFromAtlas(userId: uid)
    }

    /// Push contacts and settings to Atlas (contacts and settings only; incidents are
    /// pushed individually as they are logged).
    func syncToCloud() async {
        guard let uid = userId else { return }
        await EmergencyContactsManager.shared.pushToAtlas(userId: uid)
        await AppSettings.shared.pushToAtlas(userId: uid)
    }

    // MARK: - Private

    private func applyProfile(_ profile: UserProfile) {
        isAuthenticated = true
        userId    = profile.sub
        userName  = profile.name ?? profile.givenName
        userEmail = profile.email
    }

    private func restoreSession() async {
        do {
            let creds = try await credManager.credentials()
            let profile = try await Auth0.authentication()
                .userInfo(withAccessToken: creds.accessToken)
                .start()
            applyProfile(profile)
            if let uid = userId {
                await EmergencyContactsManager.shared.pullFromAtlas(userId: uid)
                await AppSettings.shared.pullFromAtlas(userId: uid)
            }
        } catch {
            // No valid stored session — user will log in manually.
        }
    }
}
