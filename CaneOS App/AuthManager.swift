import Foundation
import Combine
import Auth0

/// Manages the Auth0 login session and triggers MongoDB Atlas cloud sync.
///
/// Beyond login, the Auth0 session is the app's API credential: every request
/// AtlasClient makes to the backend carries the Auth0-issued ID token, which
/// the backend verifies against the tenant's JWKS and uses to scope all
/// MongoDB reads/writes to this user server-side.
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
/// ─────────────────────────────────────────────────────────────────────────
@MainActor
final class AuthManager: ObservableObject {
    static let shared = AuthManager()

    @Published var isAuthenticated = false
    @Published var userId:     String?
    @Published var userName:   String?
    @Published var userEmail:  String?
    @Published var userPicture: URL?
    @Published var isSyncing   = false
    /// True while checking for a stored session at launch, so the UI can
    /// hold on a splash instead of flashing the sign-in screen.
    @Published var isRestoring = true

    private let credManager = CredentialsManager(authentication: Auth0.authentication())

    private init() {
        Task { await restoreSession() }
    }

    // MARK: - Auth

    func login() async {
        do {
            // offline_access asks Auth0 for a refresh token so the
            // CredentialsManager can silently renew the session (and the
            // ID token AtlasClient sends to the backend) when it expires.
            let creds = try await Auth0.webAuth()
                .scope("openid profile email offline_access")
                .start()
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
        userId = nil; userName = nil; userEmail = nil; userPicture = nil
        // Role belongs to the account, not the device — clear it so the next
        // sign-in restores it from that account's cloud settings (or shows
        // account setup for a fresh account).
        AppSettings.shared.userRole = nil
    }

    /// A fresh Auth0 ID token for authenticating backend requests.
    /// CredentialsManager transparently renews expired credentials using the
    /// stored refresh token. Returns nil when signed out.
    func bearerToken() async -> String? {
        guard isAuthenticated else { return nil }
        return try? await credManager.credentials().idToken
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
        userId      = profile.sub
        userName    = profile.name ?? profile.givenName
        userEmail   = profile.email
        userPicture = profile.picture
    }

    private func restoreSession() async {
        defer { isRestoring = false }
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
