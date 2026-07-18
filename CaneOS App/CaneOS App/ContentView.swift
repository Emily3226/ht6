import SwiftUI
import MapKit
import CoreLocation
import UIKit

// MARK: - Color palette

extension Color {
    static let caneNavy = Color(red: 0.04, green: 0.08, blue: 0.22)
    static let caneCard = Color(red: 0.08, green: 0.18, blue: 0.38)
    static let caneBlue = Color(red: 0.12, green: 0.46, blue: 1.00)
    static let caneRed  = Color(red: 0.90, green: 0.10, blue: 0.10)
}

// MARK: - Logo mark

struct CaneMarkView: View {
    var height: CGFloat = 40
    var color: Color = .caneBlue

    var body: some View {
        Canvas { context, size in
            let lw = size.width * 0.16
            let cx = size.width * 0.78

            // Shaft
            var shaft = Path()
            shaft.move(to: CGPoint(x: cx, y: size.height * 0.30))
            shaft.addLine(to: CGPoint(x: cx, y: size.height))
            context.stroke(shaft, with: .color(color),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))

            // Hook handle — arcs from shaft-top over to the left
            var hook = Path()
            hook.move(to: CGPoint(x: cx, y: size.height * 0.30))
            hook.addCurve(
                to: CGPoint(x: cx - size.width * 0.70, y: size.height * 0.28),
                control1: CGPoint(x: cx, y: 0),
                control2: CGPoint(x: cx - size.width * 0.70, y: 0)
            )
            context.stroke(hook, with: .color(color),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))
        }
        .frame(width: height * 0.75, height: height)
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var phoneSession    = PhoneSessionManager.shared
    @StateObject private var contactsManager = EmergencyContactsManager.shared
    @StateObject private var settings        = AppSettings.shared
    @StateObject private var incidents       = IncidentStore.shared
    @StateObject private var auth            = AuthManager.shared

    // Two independent sockets, matching the backend's split:
    // /ws/haptics -- immediate, unthrottled, 3-value direction only.
    // /ws/hazards -- richer, throttled by the backend, drives audio/UI.
    @State private var hapticsConnection   = CaneSocketConnection<HapticMessage>()
    @State private var hazardsConnection   = CaneSocketConnection<CaneHazardChannelEvent>()
    @State private var sosManager          = SOSManager()
    @State private var lastHazard: HazardMessage?
    @State private var isScanning          = false
    @State private var isHardwareConnected = false
    @State private var sosCountdown: Int?  = nil
    @State private var sosTask: Task<Void, Never>?
    @State private var sosErrorMessage: String?
    @State private var pendingSOSIncidentId: UUID?

    private let elevenLabs = ElevenLabsClient(apiKey: Config.elevenLabsAPIKey, voiceId: Config.elevenLabsVoiceId)
    private let backboard  = BackboardClient(apiKey: Config.backboardAPIKey)

    var body: some View {
        // Launch flow: hold on a splash while the stored Auth0 session
        // restores → sign in → pick a role (account setup) → the app.
        Group {
            if auth.isRestoring {
                ZStack {
                    Color.caneNavy.ignoresSafeArea()
                    VStack(spacing: 16) {
                        CaneMarkView(height: 64, color: .caneBlue)
                        ProgressView().tint(.caneBlue)
                    }
                }
            } else if !auth.isAuthenticated {
                WelcomeView(auth: auth)
            } else if settings.userRole == nil {
                RoleSelectionView(auth: auth, settings: settings)
            } else {
                mainTabs
            }
        }
        .onChange(of: settings.locationSharingEnabled) { syncLocationSharing() }
        .onChange(of: settings.userRole) { syncLocationSharing() }
        .onChange(of: auth.isAuthenticated) { syncLocationSharing() }
    }

    private var mainTabs: some View {
        TabView {
            NavigationStack {
                HomeView(
                    isConnected: isHardwareConnected,
                    isWatchConnected: phoneSession.isWatchConnected,
                    lastHazard: lastHazard,
                    isScanning: isScanning,
                    onScan: requestSceneDescription,
                    onRefresh: { phoneSession.refreshWatchReachability() }
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Color.caneNavy, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            CaneMarkView(height: 22, color: .caneBlue)
                            Text("CaneOS")
                                .font(.system(size: 17, weight: .black))
                                .foregroundColor(.white)
                                .tracking(1.5)
                        }
                    }
                }
            }
            .tabItem { Label("Home", systemImage: "house.fill") }

            if settings.userRole == .support {
                NavigationStack {
                    SupportMapView(settings: settings)
                        .navigationTitle("Location")
                        .toolbarBackground(Color.caneNavy, for: .navigationBar)
                        .toolbarColorScheme(.dark, for: .navigationBar)
                }
                .tabItem { Label("Location", systemImage: "map.fill") }
            }

            NavigationStack {
                SettingsView(settings: settings, auth: auth)
                    .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }

            NavigationStack {
                SafetyView(contactsManager: contactsManager, onSOS: startSOSSequence)
                    .navigationTitle("Safety")
            }
            .tabItem { Label("Safety", systemImage: "sos.circle.fill") }

            NavigationStack {
                HistoryView(store: incidents)
                    .navigationTitle("History")
            }
            .tabItem { Label("History", systemImage: "clock.fill") }
        }
        .tint(.caneBlue)
        .onAppear {
            connectToBackend()
            syncLocationSharing()
        }
        .overlay {
            if let countdown = sosCountdown {
                SOSCountdownOverlay(countdown: countdown, onCancel: cancelSOS)
                    .ignoresSafeArea()
            }
        }
        .alert(
            "SOS Alert Failed",
            isPresented: Binding(
                get: { sosErrorMessage != nil },
                set: { if !$0 { sosErrorMessage = nil } }
            ),
            presenting: sosErrorMessage
        ) { _ in
            Button("OK", role: .cancel) { sosErrorMessage = nil }
        } message: { message in
            Text(message)
        }
    }

    /// Publishes live location to Atlas only while a signed-in primary user
    /// has the sharing toggle on.
    private func syncLocationSharing() {
        if auth.isAuthenticated,
           settings.userRole == .primary,
           settings.locationSharingEnabled {
            LocationSharingManager.shared.start()
        } else {
            LocationSharingManager.shared.stop()
        }
    }

    // MARK: - Backend wiring

    private func connectToBackend() {
        // /ws/haptics: immediate, unthrottled. The handler does exactly one
        // thing -- forward the buzz -- with nothing else on the path (no
        // logging, no async work, no awaiting) so nothing here adds latency
        // between the sensor firing on the backend and the Watch buzzing.
        hapticsConnection.onMessage = { message in
            phoneSession.sendHaptic(message.direction)
        }
        hapticsConnection.connect(to: Config.hapticsWebSocketURL)

        // /ws/hazards: richer, backend-throttled. Drives the UI, TTS, SOS,
        // and incident history.
        hazardsConnection.onConnectionChange = { connected in
            isHardwareConnected = connected
        }
        hazardsConnection.onMessage = { event in
            Task { @MainActor in
                switch event {
                case .hazard(let hazard):
                    handleHazard(hazard)
                case .sceneDescription(let text):
                    await handleSceneDescription(text)
                }
            }
        }
        hazardsConnection.connect(to: Config.hazardsWebSocketURL)
    }

    private func handleHazard(_ hazard: HazardMessage) {
        lastHazard = hazard
        isScanning = false
        let incidentId = incidents.log(
            hazardType: hazard.hazardType,
            direction:  hazard.direction.rawValue,
            urgency:    hazard.urgency
        )

        if hazard.urgency == "high" {
            // High-urgency hazards trigger the SOS flow, which fetches location
            // anyway to send with the alert -- reuse that fetch for the incident's
            // location snapshot instead of requesting location twice.
            pendingSOSIncidentId = incidentId
        } else {
            // Best-effort geolocation snapshot for the History entry. Failures
            // here (permission denied, no fix yet) are expected and non-fatal,
            // so we stay silent rather than alerting for every logged incident.
            Task {
                if let location = try? await sosManager.requestLocation() {
                    incidents.attachLocation(location, toIncidentWithId: incidentId)
                    await announceRepeatHazardIfAny(hazard, at: location, incidentId: incidentId)
                }
            }
        }

        guard settings.audioEnabled else { return }
        let desc = hazard.spokenDescription

        if hazard.urgency == "high" {
            // TTS and SOS fire in parallel — UI countdown runs concurrently with audio
            phoneSession.sendSOSAlert()
            startSOSSequence()
            Task { await speakAndPlay(desc) }
        } else {
            Task { await speakAndPlay(desc) }
        }
    }

    /// Checks Atlas ($geoNear on the incident log) for past incidents of the
    /// same hazard type within ~40 m and, if any exist, speaks a "you've
    /// encountered this here before" callback after the main narration.
    private func announceRepeatHazardIfAny(_ hazard: HazardMessage,
                                           at location: CLLocation,
                                           incidentId: UUID) async {
        guard settings.audioEnabled,
              let uid = AuthManager.shared.userId else { return }
        let repeats = await incidents.nearbyRepeatCount(
            hazardType: hazard.hazardType,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            excluding: incidentId,
            userId: uid
        )
        guard repeats > 0 else { return }
        let hazardName = hazard.hazardType.replacingOccurrences(of: "_", with: " ")
        let times = repeats == 1 ? "once" : "\(repeats) times"
        await speakAndPlay("Heads up — you've encountered a \(hazardName) at this spot \(times) before.")
    }

    private func startSOSSequence() {
        guard sosCountdown == nil else { return }
        sosCountdown = 5
        sosTask = Task {
            for remaining in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run { withAnimation { sosCountdown = remaining } }
            }
            await MainActor.run { sosCountdown = nil }
            guard !Task.isCancelled else { return }
            await fireSOS()
        }
    }

    private func cancelSOS() {
        sosTask?.cancel()
        sosTask = nil
        sosCountdown = nil
        phoneSession.sendSOSClear()
        sosManager.stopLiveUpdates()
    }

    private func fireSOS() async {
        do {
            let location = try await sosManager.requestLocation()

            // Attach this location snapshot to History: either the hazard
            // incident that triggered this SOS, or (for a manually-held SOS
            // button with no preceding hazard) a fresh "manual SOS" entry.
            let incidentId = pendingSOSIncidentId ?? incidents.log(
                hazardType: "manual_sos", direction: "-", urgency: "high"
            )
            incidents.attachLocation(location, toIncidentWithId: incidentId)
            pendingSOSIncidentId = nil

            try await sosManager.sendEmergencyAlert(
                to: contactsManager.contacts,
                location: location,
                backendURL: Config.atlasDataAPIURL,
                backendAPIKey: Config.atlasAPIKey
            )

            // Keep contacts updated with a fresh location text every
            // ~90s for as long as the SOS stays active, instead of one
            // static pin from the moment it fired.
            sosManager.startLiveUpdates(
                to: contactsManager.contacts,
                backendURL: Config.atlasDataAPIURL,
                backendAPIKey: Config.atlasAPIKey
            )
        } catch {
            sosErrorMessage = error.localizedDescription
        }
    }

    private func requestSceneDescription() {
        isScanning = true
        hazardsConnection.sendCommand("scan_now")
    }

    private func handleSceneDescription(_ text: String) async {
        isScanning = false
        do {
            let reply = try await backboard.send(text: text)
            await speakAndPlay(reply)
        } catch {
            await speakAndPlay(text)
        }
    }

    private func speakAndPlay(_ text: String) async {
        do {
            let audio = try await elevenLabs.synthesize(text: text)
            AudioPlaybackManager.shared.play(audio)
        } catch {
            print("ElevenLabs synthesis failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Home tab

struct HomeView: View {
    let isConnected: Bool
    let isWatchConnected: Bool
    let lastHazard: HazardMessage?
    let isScanning: Bool
    let onScan: () -> Void
    let onRefresh: () async -> Void

    var body: some View {
        ZStack {
            Color.caneNavy.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 20) {
                    statusCard
                    watchPill
                    if let hazard = lastHazard { lastAlertCard(hazard) }
                    scanButton
                }
                .padding()
            }
            .refreshable { await onRefresh() }
        }
    }

    private var statusCard: some View {
        VStack(spacing: 14) {
            Image(systemName: isConnected
                  ? "dot.radiowaves.left.and.right"
                  : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 52, weight: .thin))
                .foregroundColor(isConnected ? .caneBlue : Color(white: 0.40))

            Text(isConnected ? "System Connected" : "Hardware Disconnected")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                Circle()
                    .fill(isConnected ? Color.green : Color(white: 0.30))
                    .frame(width: 10, height: 10)
                Text(isConnected ? "Active" : "Offline")
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.60))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 20)
        .background(Color.caneCard)
        .cornerRadius(24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isConnected
            ? "System connected and active"
            : "Hardware disconnected, system offline")
    }

    private var watchPill: some View {
        HStack(spacing: 12) {
            Image(systemName: isWatchConnected ? "applewatch" : "applewatch.slash")
                .font(.title3)
                .foregroundColor(isWatchConnected ? .caneBlue : Color(white: 0.40))
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Watch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(isWatchConnected ? "Connected" : "Not reachable")
                    .font(.caption)
                    .foregroundColor(isWatchConnected ? .green : Color(white: 0.50))
            }
            Spacer()
            Circle()
                .fill(isWatchConnected ? Color.green : Color(white: 0.25))
                .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.caneCard)
        .cornerRadius(14)
        .accessibilityLabel(isWatchConnected
            ? "Apple Watch connected"
            : "Apple Watch not reachable")
    }

    private func lastAlertCard(_ hazard: HazardMessage) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Last Alert")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.50))
                    .textCase(.uppercase)
                Text(hazard.hazardType.capitalized)
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(hazard.direction.rawValue) · \(hazard.urgency) urgency")
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.60))
            }
            Spacer()
        }
        .padding(18)
        .background(Color.caneCard)
        .cornerRadius(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last alert: \(hazard.hazardType), \(hazard.direction.rawValue), \(hazard.urgency) urgency")
    }

    private var scanButton: some View {
        Button(action: onScan) {
            HStack(spacing: 12) {
                Image(systemName: isScanning ? "camera.fill" : "camera.viewfinder")
                    .font(.title2)
                Text(isScanning ? "Scanning…" : "What's around me?")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(isScanning ? Color(white: 0.20) : Color.caneBlue)
            .foregroundColor(.white)
            .cornerRadius(16)
        }
        .disabled(isScanning)
        .accessibilityLabel(isScanning
            ? "Scanning environment, please wait"
            : "What's around me, scan environment")
        .accessibilityHint("Triggers a camera scan and spoken audio description of your surroundings")
    }
}

// MARK: - Settings tab

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var auth: AuthManager

    var body: some View {
        ZStack {
            Color.caneNavy.ignoresSafeArea()
            List {
                // MARK: Mode (both roles) — switchable anytime
                Section {
                    Picker("Mode", selection: Binding(
                        get: { settings.userRole ?? .primary },
                        set: { settings.userRole = $0 }
                    )) {
                        ForEach(UserRole.allCases) { role in
                            Text(role.label).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.caneCard)
                    .accessibilityLabel("App mode: \(settings.userRole?.label ?? "not set")")
                    .accessibilityHint("Switches between the visually impaired experience and the support partner experience")
                } header: {
                    sectionHeader(icon: "person.crop.rectangle.stack", title: "Mode")
                }

                if settings.userRole == .primary {
                    Section {
                        settingRow(
                            title: "Haptic Intensity",
                            hint: "Adjusts vibration strength on the clip module. Currently \(settings.hapticIntensity.label)"
                        ) {
                            Picker("Haptic Intensity", selection: $settings.hapticIntensity) {
                                ForEach(AppSettings.HapticIntensity.allCases) { level in
                                    Text(level.label).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    } header: {
                        sectionHeader(icon: "waveform.path", title: "Vibration")
                    }

                    Section {
                        settingRow(
                            title: "Detection Sensitivity",
                            hint: "Controls how aggressively the sensor flags movement. Currently \(settings.sensitivityLevel.label)"
                        ) {
                            Picker("Sensitivity", selection: $settings.sensitivityLevel) {
                                ForEach(AppSettings.SensitivityLevel.allCases) { level in
                                    Text(level.label).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    } header: {
                        sectionHeader(icon: "sensor.tag.radiowaves.forward", title: "Sensor")
                    }

                    Section {
                        Toggle(isOn: $settings.audioEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Hazard Narration")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.white)
                                Text("Spoken obstacle descriptions via headphones")
                                    .font(.caption)
                                    .foregroundColor(Color(white: 0.55))
                            }
                        }
                        .tint(.caneBlue)
                        .listRowBackground(Color.caneCard)
                        .accessibilityLabel("Hazard audio narration \(settings.audioEnabled ? "on" : "off")")
                        .accessibilityHint("Toggles spoken descriptions for detected obstacles")
                    } header: {
                        sectionHeader(icon: "speaker.wave.2.fill", title: "Audio")
                    }

                    // MARK: Location sharing (primary role only)
                    Section {
                        Toggle(isOn: $settings.locationSharingEnabled) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Share Live Location")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.white)
                                Text("Lets your support partner see where you are on their map")
                                    .font(.caption)
                                    .foregroundColor(Color(white: 0.55))
                            }
                        }
                        .tint(.caneBlue)
                        .listRowBackground(Color.caneCard)
                        .accessibilityLabel("Live location sharing \(settings.locationSharingEnabled ? "on" : "off")")
                        .accessibilityHint("When on, your support partner can follow your location on a map. Turn off anytime.")

                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your share code")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.white)
                                Text("Your support partner enters this in their app")
                                    .font(.caption)
                                    .foregroundColor(Color(white: 0.55))
                            }
                            Spacer()
                            Text(settings.shareCode)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(.caneBlue)
                                .textSelection(.enabled)
                        }
                        .listRowBackground(Color.caneCard)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Your share code is \(settings.shareCode.map(String.init).joined(separator: " "))")
                    } header: {
                        sectionHeader(icon: "location.fill", title: "Location Sharing")
                    }
                }

                if settings.userRole == .support {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Following code")
                                    .font(.body.weight(.semibold))
                                    .foregroundColor(.white)
                                Text("Set or change it from the Location tab")
                                    .font(.caption)
                                    .foregroundColor(Color(white: 0.55))
                            }
                            Spacer()
                            Text(settings.followCode.isEmpty ? "—" : settings.followCode)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundColor(settings.followCode.isEmpty ? Color(white: 0.40) : .caneBlue)
                        }
                        .listRowBackground(Color.caneCard)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(settings.followCode.isEmpty
                            ? "Not following anyone yet. Set a share code from the Location tab."
                            : "Following share code \(settings.followCode.map(String.init).joined(separator: " "))")
                    } header: {
                        sectionHeader(icon: "map.fill", title: "Following")
                    }
                }

                // MARK: Account (profile + Atlas sync; sign-in itself
                // happens on the launch screen, before the app is shown)
                Section {
                        HStack(spacing: 12) {
                            if let picture = auth.userPicture {
                                AsyncImage(url: picture) { image in
                                    image.resizable()
                                } placeholder: {
                                    Circle().fill(Color(white: 0.20))
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.caneBlue.opacity(0.6), lineWidth: 1.5))
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                if let name = auth.userName {
                                    Text(name)
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.white)
                                }
                                if let email = auth.userEmail {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundColor(Color(white: 0.55))
                                }
                                Text("Requests verified by Auth0 · data in MongoDB Atlas")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(white: 0.40))
                            }
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(Color.caneCard)

                        Button {
                            Task { await auth.syncToCloud() }
                        } label: {
                            HStack(spacing: 8) {
                                if auth.isSyncing {
                                    ProgressView().tint(.caneBlue)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .foregroundColor(.caneBlue)
                                }
                                Text(auth.isSyncing ? "Syncing…" : "Sync now")
                                    .foregroundColor(.white)
                            }
                        }
                        .disabled(auth.isSyncing)
                        .listRowBackground(Color.caneCard)
                        .accessibilityLabel("Sync contacts and settings to cloud")

                        Button(role: .destructive) {
                            Task { await auth.logout() }
                        } label: {
                            Text("Sign Out")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .font(.body.weight(.semibold))
                        }
                        .listRowBackground(Color.caneCard)
                } header: {
                    sectionHeader(icon: "person.crop.circle.fill", title: "Account")
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .toolbarBackground(Color.caneNavy, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(.caneBlue)
                .font(.subheadline.weight(.medium))
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
        }
        .textCase(nil)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func settingRow<Content: View>(
        title: String, hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundColor(.white)
            content()
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.caneCard)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
    }
}

// MARK: - Country dial codes

private struct CountryDialCode: Identifiable, Hashable {
    let id: String
    let name: String
    let dialCode: String
    let maxDigits: Int
    let formatTemplate: String  // '_' marks a digit slot; other chars are literals

    static let all: [CountryDialCode] = [
        CountryDialCode(id: "US", name: "United States",        dialCode: "+1",   maxDigits: 10, formatTemplate: "(___) ___-____"),
        CountryDialCode(id: "CA", name: "Canada",               dialCode: "+1",   maxDigits: 10, formatTemplate: "(___) ___-____"),
        CountryDialCode(id: "GB", name: "United Kingdom",       dialCode: "+44",  maxDigits: 10, formatTemplate: "____ ______"),
        CountryDialCode(id: "AU", name: "Australia",            dialCode: "+61",  maxDigits: 9,  formatTemplate: "___ ___ ___"),
        CountryDialCode(id: "IN", name: "India",                dialCode: "+91",  maxDigits: 10, formatTemplate: "_____-_____"),
        CountryDialCode(id: "DE", name: "Germany",              dialCode: "+49",  maxDigits: 11, formatTemplate: "_____ ______"),
        CountryDialCode(id: "FR", name: "France",               dialCode: "+33",  maxDigits: 9,  formatTemplate: "___ ___ ___"),
        CountryDialCode(id: "JP", name: "Japan",                dialCode: "+81",  maxDigits: 10, formatTemplate: "__-____-____"),
        CountryDialCode(id: "CN", name: "China",                dialCode: "+86",  maxDigits: 11, formatTemplate: "___-____-____"),
        CountryDialCode(id: "BR", name: "Brazil",               dialCode: "+55",  maxDigits: 11, formatTemplate: "(__) _____-____"),
        CountryDialCode(id: "MX", name: "Mexico",               dialCode: "+52",  maxDigits: 10, formatTemplate: "(__) ____-____"),
        CountryDialCode(id: "ES", name: "Spain",                dialCode: "+34",  maxDigits: 9,  formatTemplate: "___-___-___"),
        CountryDialCode(id: "IT", name: "Italy",                dialCode: "+39",  maxDigits: 10, formatTemplate: "___-____-___"),
        CountryDialCode(id: "NL", name: "Netherlands",          dialCode: "+31",  maxDigits: 9,  formatTemplate: "__-___-____"),
        CountryDialCode(id: "KR", name: "South Korea",          dialCode: "+82",  maxDigits: 10, formatTemplate: "___-___-____"),
        CountryDialCode(id: "NG", name: "Nigeria",              dialCode: "+234", maxDigits: 10, formatTemplate: "___-___-____"),
        CountryDialCode(id: "ZA", name: "South Africa",         dialCode: "+27",  maxDigits: 9,  formatTemplate: "__-___-____"),
        CountryDialCode(id: "SG", name: "Singapore",            dialCode: "+65",  maxDigits: 8,  formatTemplate: "____-____"),
        CountryDialCode(id: "AE", name: "United Arab Emirates", dialCode: "+971", maxDigits: 9,  formatTemplate: "__-___-____"),
        CountryDialCode(id: "SE", name: "Sweden",               dialCode: "+46",  maxDigits: 9,  formatTemplate: "__-___-____"),
        CountryDialCode(id: "NO", name: "Norway",               dialCode: "+47",  maxDigits: 8,  formatTemplate: "____-____"),
        CountryDialCode(id: "PH", name: "Philippines",          dialCode: "+63",  maxDigits: 10, formatTemplate: "___-___-____"),
        CountryDialCode(id: "PK", name: "Pakistan",             dialCode: "+92",  maxDigits: 10, formatTemplate: "___-_______"),
        CountryDialCode(id: "TR", name: "Turkey",               dialCode: "+90",  maxDigits: 10, formatTemplate: "(___) ___-____"),
        CountryDialCode(id: "SA", name: "Saudi Arabia",         dialCode: "+966", maxDigits: 9,  formatTemplate: "___-___-___"),
        CountryDialCode(id: "AR", name: "Argentina",            dialCode: "+54",  maxDigits: 10, formatTemplate: "(__) ____-____"),
        CountryDialCode(id: "NZ", name: "New Zealand",          dialCode: "+64",  maxDigits: 9,  formatTemplate: "___-___-___"),
    ]

    /// Splits a stored E.164-style number into its matching country and raw digit string.
    static func parse(_ number: String) -> (country: CountryDialCode, digits: String) {
        // Try longest dial codes first to avoid prefix ambiguity (e.g. +234 before +23)
        let sorted = all.sorted { $0.dialCode.count > $1.dialCode.count }
        for country in sorted where number.hasPrefix(country.dialCode) {
            return (country, String(number.dropFirst(country.dialCode.count)))
        }
        return (all[0], number.filter { $0.isNumber })
    }
}

// MARK: - Conflict alert state

private enum ConflictType {
    case primary(EmergencyContact)
    case secondary(EmergencyContact)

    var alertTitle: String {
        switch self {
        case .primary:  "Primary Contact Conflict"
        case .secondary: "Secondary Contact Conflict"
        }
    }
}

// MARK: - Safety tab (SOS + Contacts)

struct SafetyView: View {
    @ObservedObject var contactsManager: EmergencyContactsManager
    let onSOS: () -> Void

    @State private var newName = ""
    @State private var newPhone = ""
    @State private var selectedCountry = CountryDialCode.all[0]
    @State private var newCarrier: Carrier = .bell
    @State private var newPriority: ContactPriority = .none
    @State private var phoneError: String?
    @State private var pendingConflict: ConflictType?
    @State private var editingContact: EmergencyContact?
    @GestureState private var isPressing = false
    @State private var holdProgress: Double = 0
    @State private var holdTimer: Timer?
    @State private var sosFired = false

    private let holdDuration = 3.0
    private var canAdd: Bool { !newName.isEmpty && !newPhone.isEmpty }

    @ViewBuilder
    private func priorityBadge(_ priority: ContactPriority) -> some View {
        Text(priority == .primary ? "PRIMARY" : "SECONDARY")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.4)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(priority == .primary
                        ? Color.caneBlue.opacity(0.22)
                        : Color.orange.opacity(0.20))
            .foregroundColor(priority == .primary ? Color.caneBlue : Color.orange)
            .cornerRadius(3)
    }

    // Renders the format template with typed digits in white and empty slots dimmed
    private var phoneFormatMask: some View {
        var attributed = AttributedString()
        var idx = newPhone.startIndex
        for ch in selectedCountry.formatTemplate {
            if ch == "_" {
                if idx < newPhone.endIndex {
                    var a = AttributedString(String(newPhone[idx]))
                    a.foregroundColor = .white
                    attributed += a
                    idx = newPhone.index(after: idx)
                } else {
                    var a = AttributedString("_")
                    a.foregroundColor = Color(white: 0.28)
                    attributed += a
                }
            } else {
                var a = AttributedString(String(ch))
                a.foregroundColor = Color(white: 0.45)
                attributed += a
            }
        }
        return Text(attributed)
            .font(.system(size: 15, design: .monospaced))
    }

    var body: some View {
        List {
            // SOS button — full-bleed row inside the list
            Section {
                sosButtonSection
                    .listRowBackground(Color.caneNavy)
                    .listRowInsets(EdgeInsets())
            }

            // Add-contact form — blue header makes it clearly the input area
            Section {
                TextField("Name", text: $newName)
                    .listRowBackground(Color.caneCard)

                Picker("Country", selection: $selectedCountry) {
                    ForEach(CountryDialCode.all) { country in
                        Text("\(country.name) (\(country.dialCode))").tag(country)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.caneBlue)
                .listRowBackground(Color.caneCard)

                // Phone field — digits only, capped at country max, live format mask below
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(selectedCountry.dialCode)
                            .foregroundColor(Color(white: 0.55))
                        TextField("Phone number", text: $newPhone)
                            .keyboardType(.phonePad)
                            .onChange(of: newPhone) { _, newValue in
                                let digits = newValue.filter { $0.isNumber }
                                let limited = String(digits.prefix(selectedCountry.maxDigits))
                                if limited != newPhone { newPhone = limited }
                                phoneError = nil
                            }
                    }
                    phoneFormatMask
                    if let error = phoneError {
                        Text(error).font(.caption).foregroundColor(.red)
                    }
                }
                .listRowBackground(Color.caneCard)
                .onChange(of: selectedCountry) { _, _ in
                    newPhone = ""
                    phoneError = nil
                }

                // Carrier — needed to build the email-to-SMS gateway address
                // that SOSManager sends the emergency alert to.
                Picker("Carrier", selection: $newCarrier) {
                    ForEach(Carrier.allCases) { carrier in
                        Text(carrier.displayName).tag(carrier)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color.caneBlue)
                .listRowBackground(Color.caneCard)
                .accessibilityHint("Needed so SOS alerts can be delivered as a text message")

                Picker("Priority", selection: $newPriority) {
                    Text("No priority").tag(ContactPriority.none)
                    Text("Primary contact").tag(ContactPriority.primary)
                    Text("Secondary contact").tag(ContactPriority.secondary)
                }
                .pickerStyle(.menu)
                .tint(newPriority == .primary ? Color.caneBlue
                      : newPriority == .secondary ? Color.orange
                      : Color(white: 0.55))
                .listRowBackground(Color.caneCard)

                Button(action: addContact) {
                    Label("Add Contact", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .foregroundColor(.white)
                }
                .disabled(!canAdd)
                .listRowBackground(canAdd ? Color.caneBlue : Color(white: 0.18))
                .accessibilityLabel("Add emergency contact")
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: "person.badge.plus")
                    Text("ADD NEW CONTACT")
                }
                .font(.caption.bold())
                .foregroundColor(Color.caneBlue)
                .textCase(nil)
            }

            // Saved contacts — distinct header, sorted: primary → secondary → A-Z
            Section {
                if contactsManager.contacts.isEmpty {
                    Text("No emergency contacts yet.\nAdd one above.")
                        .font(.subheadline)
                        .foregroundColor(Color(white: 0.40))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.caneNavy)
                } else {
                    ForEach(contactsManager.sortedContacts) { contact in
                        HStack(spacing: 12) {
                            // Coloured left stripe for primary/secondary
                            RoundedRectangle(cornerRadius: 2)
                                .fill(contact.priority == .primary ? Color.caneBlue
                                      : contact.priority == .secondary ? Color.orange
                                      : Color.clear)
                                .frame(width: 3)

                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) {
                                    Text(contact.name)
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    if contact.priority != .none {
                                        priorityBadge(contact.priority)
                                    }
                                }
                                Text(contact.phoneNumber)
                                    .font(.subheadline)
                                    .foregroundColor(Color(white: 0.55))
                                Text(contact.carrier.displayName)
                                    .font(.caption)
                                    .foregroundColor(Color(white: 0.40))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Emergency contact: \(contact.name), \(contact.phoneNumber)\(contact.priority != .none ? ", \(contact.priority.rawValue) contact" : "")")
                        .listRowBackground(Color.caneCard)
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingContact = contact
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(Color.caneBlue)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if let i = contactsManager.contacts.firstIndex(where: { $0.id == contact.id }) {
                                    contactsManager.remove(at: IndexSet(integer: i))
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            if contact.priority != .primary {
                                Button {
                                    contactsManager.setPriority(.primary, for: contact.id)
                                } label: {
                                    Label("Set as Primary", systemImage: "star.fill")
                                }
                            }
                            if contact.priority != .secondary {
                                Button {
                                    contactsManager.setPriority(.secondary, for: contact.id)
                                } label: {
                                    Label("Set as Secondary", systemImage: "star.leadinghalf.filled")
                                }
                            }
                            if contact.priority != .none {
                                Divider()
                                Button(role: .destructive) {
                                    contactsManager.setPriority(.none, for: contact.id)
                                } label: {
                                    Label("Remove Priority", systemImage: "star.slash")
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                        Text("SAVED CONTACTS")
                    }
                    .font(.caption.bold())
                    .foregroundColor(.white)
                    .textCase(nil)
                    Spacer()
                    if !contactsManager.contacts.isEmpty {
                        Text("\(contactsManager.contacts.count)")
                            .font(.caption.bold())
                            .monospacedDigit()
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(white: 0.18))
                            .foregroundColor(Color(white: 0.55))
                            .cornerRadius(8)
                    }
                }
                .padding(.top, 8)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.caneNavy)
        .sheet(item: $editingContact) { contact in
            EditContactSheet(contact: contact, manager: contactsManager) {
                editingContact = nil
            }
        }
        .alert(
            pendingConflict?.alertTitle ?? "",
            isPresented: Binding(
                get: { pendingConflict != nil },
                set: { if !$0 { pendingConflict = nil } }
            ),
            presenting: pendingConflict
        ) { conflict in
            if case .primary(let existing) = conflict {
                Button("Make \(newName) primary, bump \(existing.name) to secondary") {
                    commitAdd(bumpPrimary: true)
                }
                Button("Make \(newName) primary") {
                    commitAdd(bumpPrimary: false)
                }
            } else if case .secondary(let existing) = conflict {
                Button("Make \(newName) secondary, bump \(existing.name) to normal") {
                    commitAdd(bumpPrimary: false)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { conflict in
            if case .primary(let existing) = conflict {
                Text("\(existing.name) is already set as your primary contact.")
            } else if case .secondary(let existing) = conflict {
                Text("\(existing.name) is already set as your secondary contact.")
            }
        }
        .onChange(of: isPressing) { _, pressing in
            if pressing { startHold() } else { cancelHold() }
        }
    }

    // Hold-to-activate SOS with animated progress ring
    private var sosButtonSection: some View {
        VStack(spacing: 14) {
            Text(sosFired ? "SOS Sent" : "Emergency SOS")
                .font(.title3.bold())
                .foregroundColor(sosFired ? .green : .white)

            ZStack {
                Circle()
                    .fill(sosFired
                        ? Color.green.opacity(0.20)
                        : Color.caneRed.opacity(0.14))
                    .frame(width: 200, height: 200)
                Circle()
                    .stroke(Color(white: 0.14), lineWidth: 10)
                    .frame(width: 200, height: 200)
                Circle()
                    .trim(from: 0, to: holdProgress / holdDuration)
                    .stroke(Color.caneRed,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .frame(width: 200, height: 200)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.05), value: holdProgress)
                VStack(spacing: 6) {
                    Image(systemName: sosFired ? "checkmark.circle.fill" : "sos.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(sosFired ? .green : .white)
                    Text(sosFired ? "SENT" : "HOLD 3s")
                        .font(.system(size: 15, weight: .black))
                        .foregroundColor(.white)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isPressing) { _, state, _ in state = true }
            )
            .accessibilityLabel("Emergency SOS button")
            .accessibilityHint("Hold for three seconds to send emergency alert to your contacts with your location")
            .accessibilityAddTraits(.isButton)

            Text("Hold 3 seconds to alert emergency contacts")
                .font(.footnote)
                .foregroundColor(Color(white: 0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func addContact() {
        let digits = newPhone.filter { $0.isNumber }
        guard digits.count >= 7 else {
            phoneError = "Enter at least 7 digits"
            return
        }
        guard digits.count <= 15 else {
            phoneError = "Number too long (max 15 digits)"
            return
        }
        if newPriority == .primary,
           let existing = contactsManager.contacts.first(where: { $0.priority == .primary }) {
            pendingConflict = .primary(existing)
            return
        }
        if newPriority == .secondary,
           let existing = contactsManager.contacts.first(where: { $0.priority == .secondary }) {
            pendingConflict = .secondary(existing)
            return
        }
        commitAdd(bumpPrimary: false)
    }

    private func commitAdd(bumpPrimary: Bool) {
        let digits = newPhone.filter { $0.isNumber }
        contactsManager.add(
            name: newName,
            phoneNumber: "\(selectedCountry.dialCode)\(digits)",
            carrier: newCarrier,
            priority: newPriority,
            bumpExistingPrimaryToSecondary: bumpPrimary
        )
        newName = ""
        newPhone = ""
        newCarrier = .bell
        newPriority = .none
        phoneError = nil
    }

    private func startHold() {
        guard holdTimer == nil, !sosFired else { return }
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            holdProgress += 0.05
            if holdProgress >= holdDuration { activate() }
        }
    }

    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        withAnimation(.easeOut(duration: 0.25)) { holdProgress = 0 }
    }

    private func activate() {
        cancelHold()
        sosFired = true
        onSOS()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { sosFired = false }
    }
}

// MARK: - Edit contact sheet

private struct EditContactSheet: View {
    let contact: EmergencyContact
    @ObservedObject var manager: EmergencyContactsManager
    let onDismiss: () -> Void

    @State private var name: String
    @State private var phone: String
    @State private var selectedCountry: CountryDialCode
    @State private var carrier: Carrier
    @State private var priority: ContactPriority
    @State private var phoneError: String?
    @State private var pendingConflict: ConflictType?

    init(contact: EmergencyContact, manager: EmergencyContactsManager, onDismiss: @escaping () -> Void) {
        self.contact = contact
        self.manager = manager
        self.onDismiss = onDismiss
        let parsed = CountryDialCode.parse(contact.phoneNumber)
        _name            = State(initialValue: contact.name)
        _phone           = State(initialValue: parsed.digits)
        _selectedCountry = State(initialValue: parsed.country)
        _carrier         = State(initialValue: contact.carrier)
        _priority        = State(initialValue: contact.priority)
    }

    private var existingPrimary: EmergencyContact? {
        manager.contacts.first { $0.priority == .primary && $0.id != contact.id }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        .listRowBackground(Color.caneCard)
                } header: { Text("Name").foregroundColor(Color(white: 0.55)) }

                Section {
                    Picker("Country", selection: $selectedCountry) {
                        ForEach(CountryDialCode.all) { country in
                            Text("\(country.name) (\(country.dialCode))").tag(country)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.caneBlue)
                    .listRowBackground(Color.caneCard)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(selectedCountry.dialCode)
                                .foregroundColor(Color(white: 0.55))
                            TextField("Phone number", text: $phone)
                                .keyboardType(.phonePad)
                                .onChange(of: phone) { _, newValue in
                                    let digits = newValue.filter { $0.isNumber }
                                    let limited = String(digits.prefix(selectedCountry.maxDigits))
                                    if limited != phone { phone = limited }
                                    phoneError = nil
                                }
                        }
                        phoneFormatMask
                        if let error = phoneError {
                            Text(error).font(.caption).foregroundColor(.red)
                        }
                    }
                    .listRowBackground(Color.caneCard)
                    .onChange(of: selectedCountry) { _, _ in
                        phone = ""
                        phoneError = nil
                    }
                } header: { Text("Phone Number").foregroundColor(Color(white: 0.55)) }

                Section {
                    Picker("Carrier", selection: $carrier) {
                        ForEach(Carrier.allCases) { c in
                            Text(c.displayName).tag(c)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.caneBlue)
                    .listRowBackground(Color.caneCard)
                } header: { Text("Carrier").foregroundColor(Color(white: 0.55)) }

                Section {
                    Picker("Priority", selection: $priority) {
                        Text("No priority").tag(ContactPriority.none)
                        Text("Primary contact").tag(ContactPriority.primary)
                        Text("Secondary contact").tag(ContactPriority.secondary)
                    }
                    .pickerStyle(.menu)
                    .tint(priority == .primary ? Color.caneBlue
                          : priority == .secondary ? Color.orange
                          : Color(white: 0.55))
                    .listRowBackground(Color.caneCard)
                } header: { Text("Priority").foregroundColor(Color(white: 0.55)) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.caneNavy)
            .navigationTitle("Edit Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.caneNavy, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss).foregroundColor(Color.caneBlue)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: attemptSave)
                        .foregroundColor(Color.caneBlue)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert(
                pendingConflict?.alertTitle ?? "",
                isPresented: Binding(
                    get: { pendingConflict != nil },
                    set: { if !$0 { pendingConflict = nil } }
                ),
                presenting: pendingConflict
            ) { conflict in
                if case .primary(let existing) = conflict {
                    Button("Make \(name) primary, bump \(existing.name) to secondary") {
                        commitSave(bump: true)
                    }
                    Button("Make \(name) primary") {
                        commitSave(bump: false)
                    }
                } else if case .secondary(let existing) = conflict {
                    Button("Make \(name) secondary, bump \(existing.name) to normal") {
                        commitSave(bump: false)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: { conflict in
                if case .primary(let existing) = conflict {
                    Text("\(existing.name) is already set as your primary contact.")
                } else if case .secondary(let existing) = conflict {
                    Text("\(existing.name) is already set as your secondary contact.")
                }
            }
        }
    }

    private var phoneFormatMask: some View {
        var attributed = AttributedString()
        var idx = phone.startIndex
        for ch in selectedCountry.formatTemplate {
            if ch == "_" {
                if idx < phone.endIndex {
                    var a = AttributedString(String(phone[idx]))
                    a.foregroundColor = .white
                    attributed += a
                    idx = phone.index(after: idx)
                } else {
                    var a = AttributedString("_")
                    a.foregroundColor = Color(white: 0.28)
                    attributed += a
                }
            } else {
                var a = AttributedString(String(ch))
                a.foregroundColor = Color(white: 0.45)
                attributed += a
            }
        }
        return Text(attributed)
            .font(.system(size: 15, design: .monospaced))
    }

    private func attemptSave() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard phone.count >= 7 else { phoneError = "Enter at least 7 digits"; return }
        if priority == .primary, let existing = existingPrimary {
            pendingConflict = .primary(existing)
            return
        }
        if priority == .secondary,
           let existing = manager.contacts.first(where: { $0.priority == .secondary && $0.id != contact.id }) {
            pendingConflict = .secondary(existing)
            return
        }
        commitSave(bump: false)
    }

    private func commitSave(bump: Bool) {
        manager.update(
            id: contact.id,
            name: name.trimmingCharacters(in: .whitespaces),
            phoneNumber: "\(selectedCountry.dialCode)\(phone)",
            carrier: carrier,
            priority: priority,
            bumpExistingPrimaryToSecondary: bump
        )
        onDismiss()
    }
}

// MARK: - SOS countdown overlay

struct SOSCountdownOverlay: View {
    let countdown: Int
    let onCancel: () -> Void
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.90).ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top ~68% — alert content
                    VStack(spacing: 16) {
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(.caneRed)
                            .scaleEffect(pulse ? 1.08 : 1.0)
                            .animation(
                                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                                value: pulse)
                        Text("SOS sending in")
                            .font(.title2.bold())
                            .foregroundColor(.white)
                        Text("\(countdown)")
                            .font(.system(size: 88, weight: .black))
                            .foregroundColor(.caneRed)
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.default, value: countdown)
                        Spacer()
                    }
                    .frame(height: geo.size.height * 0.68)

                    // Bottom 32% — cancel (exceeds the 30% spec requirement)
                    Button(action: onCancel) {
                        Text("CANCEL SOS")
                            .font(.system(size: 22, weight: .black))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color.caneRed)
                    .frame(height: geo.size.height * 0.32)
                    .accessibilityLabel("Cancel emergency SOS")
                    .accessibilityHint("Double tap to cancel the emergency alert before it sends")
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { pulse = true }
    }
}

// MARK: - History tab

struct HistoryView: View {
    @ObservedObject var store: IncidentStore
    @ObservedObject private var auth = AuthManager.shared
    @Environment(\.openURL) private var openURL
    @State private var insights: IncidentStore.Insights?

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        ZStack {
            Color.caneNavy.ignoresSafeArea()
            if store.incidents.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "clock.badge.checkmark.fill")
                        .font(.system(size: 52))
                        .foregroundColor(Color(white: 0.22))
                    Text("No incidents logged yet")
                        .font(.headline)
                        .foregroundColor(Color(white: 0.40))
                }
            } else {
                List {
                    if let insights, insights.total > 0 {
                        Section {
                            insightsCard(insights)
                                .listRowBackground(Color.caneNavy)
                                .listRowInsets(EdgeInsets())
                        }
                    }
                    Section {
                        ForEach(store.incidents) { incident in
                            incidentRow(incident)
                        }
                        .onDelete(perform: store.remove)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        // Re-run the Atlas aggregation whenever the log changes or the user
        // signs in/out.
        .task(id: "\(store.incidents.count)-\(auth.userId ?? "-")") {
            await loadInsights()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !store.incidents.isEmpty {
                    EditButton()
                        .foregroundColor(.caneBlue)
                        .accessibilityLabel("Edit incident history")
                }
            }
        }
    }

    private func loadInsights() async {
        guard let uid = auth.userId else {
            insights = nil
            return
        }
        insights = await store.fetchInsights(userId: uid)
    }

    private func insightsCard(_ insights: IncidentStore.Insights) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.caneBlue)
                Text("INSIGHTS")
                    .font(.caption.bold())
                    .foregroundColor(.caneBlue)
                Spacer()
                Text("Live from Atlas")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(white: 0.45))
            }

            HStack(spacing: 10) {
                statTile(value: insights.total, label: "Total", color: .caneBlue)
                statTile(value: insights.highCount, label: "High", color: .red)
                statTile(value: insights.mediumCount, label: "Medium", color: .orange)
                statTile(value: insights.lowCount, label: "Low", color: Color(white: 0.55))
            }

            if let top = insights.topHazards.first {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                    Text("Most common: \(top.type.replacingOccurrences(of: "_", with: " ").capitalized) (\(top.count)×)")
                        .font(.caption)
                        .foregroundColor(Color(white: 0.70))
                }
            }
        }
        .padding(16)
        .background(Color.caneCard)
        .cornerRadius(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Incident insights: \(insights.total) total, \(insights.highCount) high urgency, \(insights.mediumCount) medium, \(insights.lowCount) low")
    }

    private func statTile(value: Int, label: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text("\(value)")
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(white: 0.50))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.caneNavy.opacity(0.6))
        .cornerRadius(10)
    }

    private func incidentRow(_ incident: Incident) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    urgencyPill(incident.urgency)
                    Text(incident.hazardType.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                Text("\(incident.direction.capitalized) direction")
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.55))
                Text(Self.formatter.string(from: incident.date))
                    .font(.caption)
                    .foregroundColor(Color(white: 0.40))
            }

            Spacer(minLength: 0)

            if incident.hasLocation {
                IncidentLocationSnapshot(incident: incident)
                    .onTapGesture {
                        if let url = incident.mapsURL { openURL(url) }
                    }
                    .accessibilityLabel("Open incident location in Maps")
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Color.caneCard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(incident.urgency) urgency \(incident.hazardType) from \(incident.direction) at \(Self.formatter.string(from: incident.date))\(incident.hasLocation ? ", location recorded" : "")")
    }

    @ViewBuilder
    private func urgencyPill(_ urgency: String) -> some View {
        Text(urgency.uppercased())
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(urgencyColor(urgency))
            .foregroundColor(.white)
            .cornerRadius(6)
    }

    private func urgencyColor(_ urgency: String) -> Color {
        switch urgency.lowercased() {
        case "high":   return .red
        case "medium": return .orange
        default:       return .caneBlue
        }
    }
}

// MARK: - Incident location snapshot thumbnail

/// A small static map image for a saved incident location. Uses
/// MKMapSnapshotter (a lightweight rendered image) rather than an
/// interactive MKMapView/Map, since these appear one-per-row in a list.
struct IncidentLocationSnapshot: View {
    let incident: Incident
    @State private var image: UIImage?

    private let size = CGSize(width: 64, height: 64)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(white: 0.14))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView()
                    .tint(.caneBlue)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(white: 0.25), lineWidth: 1)
        )
        .task(id: "\(incident.latitude ?? 0),\(incident.longitude ?? 0)") {
            await loadSnapshot()
        }
    }

    private func loadSnapshot() async {
        guard let latitude = incident.latitude, let longitude = incident.longitude else { return }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)

        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        options.size = size
        options.scale = UIScreen.main.scale
        options.showsBuildings = false

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return }

        let rendered = UIGraphicsImageRenderer(size: size).image { _ in
            snapshot.image.draw(at: .zero)
            let point = snapshot.point(for: coordinate)
            let dotSize: CGFloat = 10
            let dotRect = CGRect(
                x: point.x - dotSize / 2, y: point.y - dotSize / 2,
                width: dotSize, height: dotSize
            )
            UIColor.systemRed.setFill()
            UIBezierPath(ovalIn: dotRect).fill()
        }
        image = rendered
    }
}