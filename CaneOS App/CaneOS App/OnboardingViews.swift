import SwiftUI

// MARK: - Sign-in gate

/// First screen at launch when nobody is signed in: sign in (or create an
/// account) through Auth0 before anything else.
struct WelcomeView: View {
    @ObservedObject var auth: AuthManager
    @State private var isSigningIn = false

    var body: some View {
        ZStack {
            Color.caneNavy.ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()

                CaneMarkView(height: 84, color: .caneBlue)
                Text("CaneOS")
                    .font(.system(size: 40, weight: .black))
                    .foregroundColor(.white)
                    .tracking(2)
                Text("Obstacle detection beyond the cane tip")
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.55))

                Spacer()

                Button {
                    isSigningIn = true
                    Task {
                        await auth.login()
                        isSigningIn = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        if isSigningIn {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .font(.title3)
                        }
                        Text(isSigningIn ? "Signing in…" : "Sign In or Create Account")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(isSigningIn ? Color(white: 0.20) : Color.caneBlue)
                    .foregroundColor(.white)
                    .cornerRadius(16)
                }
                .disabled(isSigningIn)
                .accessibilityLabel("Sign in or create an account")
                .accessibilityHint("Opens a secure sign-in page")

                Text("Your contacts, settings, and history sync securely to your account.")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.45))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 12)
            }
            .padding(.horizontal, 28)
        }
    }
}

// MARK: - Account setup (role selection)

/// Shown right after first sign-in: your profile up top, then choose which
/// version of the app you need. Switchable later from Settings.
struct RoleSelectionView: View {
    @ObservedObject var auth: AuthManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        ZStack {
            Color.caneNavy.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    profileCard
                        .padding(.top, 28)

                    VStack(spacing: 6) {
                        Text("How will you use CaneOS?")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Text("You can change this anytime in Settings.")
                            .font(.subheadline)
                            .foregroundColor(Color(white: 0.55))
                    }

                    roleButton(
                        role: .primary,
                        icon: "figure.walk.motion",
                        title: "I'm visually impaired",
                        subtitle: "Hazard detection, narration, haptics, and SOS — the full CaneOS experience."
                    )

                    roleButton(
                        role: .support,
                        icon: "person.2.fill",
                        title: "I'm a support partner",
                        subtitle: "Follow your loved one's live location and help manage their safety network."
                    )

                    Button(role: .destructive) {
                        Task { await auth.logout() }
                    } label: {
                        Text("Sign out")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(Color(white: 0.45))
                    }
                    .padding(.top, 6)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var profileCard: some View {
        VStack(spacing: 10) {
            if let picture = auth.userPicture {
                AsyncImage(url: picture) { image in
                    image.resizable()
                } placeholder: {
                    Circle().fill(Color(white: 0.20))
                }
                .frame(width: 74, height: 74)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.caneBlue.opacity(0.7), lineWidth: 2))
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 74))
                    .foregroundColor(Color(white: 0.30))
            }
            if let name = auth.userName {
                Text(name)
                    .font(.headline)
                    .foregroundColor(.white)
            }
            if let email = auth.userEmail {
                Text(email)
                    .font(.caption)
                    .foregroundColor(Color(white: 0.55))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signed in as \(auth.userName ?? auth.userEmail ?? "your account")")
    }

    private func roleButton(role: UserRole, icon: String,
                            title: String, subtitle: String) -> some View {
        Button {
            settings.userRole = role
            if role == .primary {
                _ = settings.ensureShareCode()
            }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundColor(.caneBlue)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(Color(white: 0.60))
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(Color(white: 0.40))
            }
            .padding(18)
            .background(Color.caneCard)
            .cornerRadius(18)
        }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
    }
}
