import SwiftUI

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
    @StateObject private var contactsManager = EmergencyContactsManager()
    @StateObject private var settings        = AppSettings.shared
    @StateObject private var incidents       = IncidentStore.shared

    @State private var caneConnection      = CaneConnection()
    @State private var sosManager          = SOSManager()
    @State private var lastHazard: CaneMessage?
    @State private var isScanning          = false
    @State private var isHardwareConnected = false
    @State private var sosCountdown: Int?  = nil
    @State private var sosTask: Task<Void, Never>?

    private let elevenLabs = ElevenLabsClient(apiKey: Config.elevenLabsAPIKey, voiceId: Config.elevenLabsVoiceId)
    private let backboard  = BackboardClient(apiKey: Config.backboardAPIKey)

    var body: some View {
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

            NavigationStack {
                SettingsView(settings: settings)
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
        .onAppear(perform: connectToBackend)
        .overlay {
            if let countdown = sosCountdown {
                SOSCountdownOverlay(countdown: countdown, onCancel: cancelSOS)
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Backend wiring

    private func connectToBackend() {
        caneConnection.onConnectionChange = { connected in
            isHardwareConnected = connected
        }
        caneConnection.onMessage = { message in
            Task { @MainActor in
                switch message.type {
                case "hazard":            handleHazard(message)
                case "scene_description": await handleSceneDescription(message)
                default: break
                }
            }
        }
        caneConnection.connect(to: Config.backendWebSocketURL)
    }

    private func handleHazard(_ hazard: CaneMessage) {
        lastHazard = hazard
        isScanning = false
        incidents.log(
            hazardType: hazard.hazardType ?? "unknown",
            direction:  hazard.direction  ?? "-",
            urgency:    hazard.urgency    ?? "-"
        )

        if let dir = hazard.direction,
           let hDir = PhoneSessionManager.HapticDirection(rawValue: dir) {
            phoneSession.sendHaptic(hDir)
        }

        guard settings.audioEnabled, let desc = hazard.spokenDescription else { return }

        if hazard.urgency == "high" {
            // TTS and SOS fire in parallel — UI countdown runs concurrently with audio
            phoneSession.sendSOSAlert()
            startSOSSequence()
            Task { await speakAndPlay(desc) }
        } else {
            Task { await speakAndPlay(desc) }
        }
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
    }

    private func fireSOS() async {
        do {
            let location = try await sosManager.requestLocation()
            try await sosManager.sendEmergencyAlert(
                to: contactsManager.contacts,
                location: location,
                accountSid: Config.twilioAccountSid,
                authToken: Config.twilioAuthToken,
                fromNumber: Config.twilioFromNumber
            )
        } catch {
            print("SOS failed: \(error.localizedDescription)")
        }
    }

    private func requestSceneDescription() {
        isScanning = true
        caneConnection.sendCommand("scan_now")
    }

    private func handleSceneDescription(_ message: CaneMessage) async {
        isScanning = false
        guard let text = message.text else { return }
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
    let lastHazard: CaneMessage?
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
        HStack(spacing: 8) {
            Image(systemName: isWatchConnected ? "applewatch" : "applewatch.slash")
                .foregroundColor(isWatchConnected ? .caneBlue : Color(white: 0.40))
            Text(isWatchConnected ? "Watch connected" : "Watch not reachable")
                .font(.subheadline)
                .foregroundColor(Color(white: 0.60))
            Spacer()
        }
        .padding(.horizontal, 4)
        .accessibilityLabel(isWatchConnected
            ? "Apple Watch connected"
            : "Apple Watch not reachable")
    }

    private func lastAlertCard(_ hazard: CaneMessage) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
                .font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Last Alert")
                    .font(.caption)
                    .foregroundColor(Color(white: 0.50))
                    .textCase(.uppercase)
                Text(hazard.hazardType?.capitalized ?? "Hazard")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(hazard.direction ?? "-") · \(hazard.urgency ?? "-") urgency")
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.60))
            }
            Spacer()
        }
        .padding(18)
        .background(Color.caneCard)
        .cornerRadius(16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Last alert: \(hazard.hazardType ?? "hazard"), \(hazard.direction ?? "unknown direction"), \(hazard.urgency ?? "unknown") urgency")
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

    var body: some View {
        ZStack {
            Color.caneNavy.ignoresSafeArea()
            Form {
                Section {
                    settingRow(
                        icon: "waveform.path",
                        title: "Haptic Intensity",
                        hint: "Adjusts vibration motor strength on the clip module. Currently \(settings.hapticIntensity.label)"
                    ) {
                        Picker("Haptic Intensity", selection: $settings.hapticIntensity) {
                            ForEach(AppSettings.HapticIntensity.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: { Text("Vibration") }

                Section {
                    settingRow(
                        icon: "sensor.tag.radiowaves.forward",
                        title: "Detection Sensitivity",
                        hint: "Controls how aggressively the time-of-flight sensor flags movement. Currently \(settings.sensitivityLevel.label)"
                    ) {
                        Picker("Sensitivity", selection: $settings.sensitivityLevel) {
                            ForEach(AppSettings.SensitivityLevel.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                } header: { Text("Sensor") }

                Section {
                    Toggle(isOn: $settings.audioEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Hazard Narration", systemImage: "speaker.wave.2.fill")
                                .foregroundColor(.primary)
                            Text("Spoken obstacle descriptions via headphones")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .tint(.caneBlue)
                    .accessibilityLabel("Hazard audio narration \(settings.audioEnabled ? "on" : "off")")
                    .accessibilityHint("Toggles ElevenLabs spoken descriptions for detected obstacles")
                } header: { Text("Audio") }
            }
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func settingRow<Content: View>(
        icon: String, title: String, hint: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.body.weight(.medium))
            content()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
    }
}

// MARK: - Safety tab (SOS + Contacts)

struct SafetyView: View {
    @ObservedObject var contactsManager: EmergencyContactsManager
    let onSOS: () -> Void

    @State private var newName  = ""
    @State private var newPhone = ""
    @GestureState private var isPressing = false
    @State private var holdProgress: Double = 0
    @State private var holdTimer: Timer?
    @State private var sosFired = false

    private let holdDuration = 3.0

    var body: some View {
        ZStack {
            Color.caneNavy.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    sosButtonSection
                    Divider().background(Color(white: 0.18)).padding(.horizontal)
                    contactsSection
                }
                .padding()
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
    }

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Emergency Contacts")
                .font(.title3.bold())
                .foregroundColor(.white)

            // Add form
            VStack(spacing: 10) {
                TextField("Name", text: $newName)
                    .padding(12)
                    .background(Color.caneCard)
                    .cornerRadius(10)
                    .accessibilityLabel("New contact name")

                TextField("Phone number", text: $newPhone)
                    .padding(12)
                    .background(Color.caneCard)
                    .cornerRadius(10)
                    .keyboardType(.phonePad)
                    .accessibilityLabel("New contact phone number")

                Button(action: addContact) {
                    Label("Add Contact", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background((newName.isEmpty || newPhone.isEmpty)
                            ? Color(white: 0.18)
                            : Color.caneBlue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .disabled(newName.isEmpty || newPhone.isEmpty)
                .accessibilityLabel("Add emergency contact")
            }

            // Contact list
            if contactsManager.contacts.isEmpty {
                Text("No emergency contacts yet.\nAdd one above.")
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.40))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            } else {
                ForEach(contactsManager.contacts) { contact in
                    contactRow(contact)
                }
            }
        }
    }

    private func contactRow(_ contact: EmergencyContact) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(contact.name)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(contact.phoneNumber)
                    .font(.subheadline)
                    .foregroundColor(Color(white: 0.55))
            }
            Spacer()
            Button(role: .destructive) {
                if let i = contactsManager.contacts.firstIndex(where: { $0.id == contact.id }) {
                    contactsManager.remove(at: IndexSet(integer: i))
                }
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.title2)
                    .foregroundColor(Color.red.opacity(0.85))
            }
            .accessibilityLabel("Remove \(contact.name)")
        }
        .padding(16)
        .background(Color.caneCard)
        .cornerRadius(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Emergency contact: \(contact.name), \(contact.phoneNumber)")
    }

    private func addContact() {
        guard !newName.isEmpty, !newPhone.isEmpty else { return }
        contactsManager.add(name: newName, phoneNumber: newPhone)
        newName = ""; newPhone = ""
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
                    ForEach(store.incidents) { incident in
                        incidentRow(incident)
                    }
                    .onDelete(perform: store.remove)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
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

    private func incidentRow(_ incident: Incident) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                urgencyPill(incident.urgency)
                Text(incident.hazardType.capitalized)
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
        .padding(.vertical, 6)
        .listRowBackground(Color.caneCard)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(incident.urgency) urgency \(incident.hazardType) from \(incident.direction) at \(Self.formatter.string(from: incident.date))")
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
