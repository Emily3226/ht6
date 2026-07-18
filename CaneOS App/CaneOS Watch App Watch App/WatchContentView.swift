import SwiftUI
import WatchKit

// MARK: - Logo mark

private struct CaneMarkView: View {
    var height: CGFloat = 16
    var color: Color

    var body: some View {
        Canvas { context, size in
            let lw = size.width * 0.16
            let cx = size.width * 0.78

            var shaft = Path()
            shaft.move(to: CGPoint(x: cx, y: size.height * 0.30))
            shaft.addLine(to: CGPoint(x: cx, y: size.height))
            context.stroke(shaft, with: .color(color),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round))

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
    @StateObject private var session = WatchSessionManager.shared

    var body: some View {
        TabView {
            WatchMainView(session: session)
            WatchSettingsView(session: session)
        }
        .tabViewStyle(.page)
        .overlay {
            if session.sosActive {
                WatchSOSOverlay(session: session)
                    .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Main tab

struct WatchMainView: View {
    @ObservedObject var session: WatchSessionManager

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 6) {
                // Logo wordmark
                HStack(spacing: 4) {
                    CaneMarkView(height: 16, color: Color(red: 0.12, green: 0.46, blue: 1.00))
                    Text("CaneOS")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(.white)
                        .tracking(0.8)
                }

                // Connection pill
                HStack(spacing: 4) {
                    Circle()
                        .fill(session.isPhoneReachable ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(session.isPhoneReachable ? "Connected" : "No phone")
                        .font(.system(size: 10))
                        .foregroundColor(Color(white: 0.50))
                }
                .accessibilityLabel(session.isPhoneReachable
                    ? "Phone connected"
                    : "Phone not reachable")

                // Scan button
                Button(action: session.requestScan) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.12, green: 0.46, blue: 1.00))
                        VStack(spacing: 4) {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundColor(.white)
                            Text("What's\naround me?")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(width: 130, height: 130)
                .buttonStyle(.plain)
                .handGestureShortcut(.primaryAction) // Double Tap on Watch S9+
                .accessibilityLabel("Scan environment, what's around me")
                .accessibilityHint("Triggers spoken audio description of surroundings. Also activatable with double tap gesture.")

                // Last hazard direction
                if session.lastDirection != "-" {
                    Text("Last: \(session.lastDirection)")
                        .font(.system(size: 9))
                        .foregroundColor(Color(white: 0.40))
                }
            }
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Settings tab

struct WatchSettingsView: View {
    @ObservedObject var session: WatchSessionManager

    var body: some View {
        List {
            Section("Vibration") {
                Picker("Intensity", selection: $session.hapticIntensity) {
                    Text("Low").tag("low")
                    Text("Med").tag("medium")
                    Text("High").tag("high")
                }
                .accessibilityLabel("Haptic intensity: \(session.hapticIntensity)")
                .accessibilityHint("Use the digital crown to change vibration strength")
            }
            Section("Audio") {
                Toggle("Narration", isOn: $session.audioEnabled)
                    .tint(Color(red: 0.12, green: 0.46, blue: 1.00))
                    .accessibilityLabel("Audio narration \(session.audioEnabled ? "on" : "off")")
                    .accessibilityHint("Toggles spoken obstacle descriptions")
            }
        }
        .listStyle(.elliptical)
        .navigationTitle("Settings")
    }
}

// MARK: - SOS overlay

struct WatchSOSOverlay: View {
    @ObservedObject var session: WatchSessionManager
    @State private var countdown = 5
    @State private var countdownTask: Task<Void, Never>?
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Pulsing red background
                Color(red: 0.85, green: 0.08, blue: 0.08)
                    .opacity(pulse ? 0.80 : 1.0)
                    .ignoresSafeArea()
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever(autoreverses: true),
                        value: pulse)

                VStack(spacing: 0) {
                    // Top 50% — countdown display
                    VStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                        Text("SOS IN")
                            .font(.system(size: 11, weight: .black))
                            .foregroundColor(.white)
                        Text("\(countdown)")
                            .font(.system(size: 36, weight: .black))
                            .foregroundColor(.white)
                            .monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(.default, value: countdown)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: geo.size.height * 0.50)

                    // Bottom 50% — cancel button (full lower half)
                    Button(action: cancelSOS) {
                        Text("CANCEL")
                            .font(.system(size: 16, weight: .black))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(Color(red: 0.50, green: 0.00, blue: 0.00))
                    .frame(height: geo.size.height * 0.50)
                    .accessibilityLabel("Cancel SOS")
                    .accessibilityHint("Double tap to cancel the emergency alert")
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            pulse = true
            WKInterfaceDevice.current().play(.failure)
            startCountdown()
        }
        .onDisappear {
            countdownTask?.cancel()
        }
    }

    private func startCountdown() {
        countdownTask = Task {
            for remaining in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation { countdown = remaining }
                    WKInterfaceDevice.current().play(.click)
                }
            }
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            await MainActor.run { session.dismissSOSOverlay() }
        }
    }

    private func cancelSOS() {
        countdownTask?.cancel()
        session.cancelSOS()
    }
}
