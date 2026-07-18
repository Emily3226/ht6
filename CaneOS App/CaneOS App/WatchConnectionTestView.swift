import SwiftUI
import WatchConnectivity

// Drop this file into: CaneOS App/CaneOS App/
// It's self-contained — uses the PhoneSessionManager that's already in your project.
//
// To view it: easiest is to temporarily swap it in as the root view.
// In CaneOS_AppApp.swift, change:
//     WindowGroup { ContentView() }
// to:
//     WindowGroup { WatchConnectionTestView() }
// Run on your iPhone (not simulator — WatchConnectivity needs a real paired Watch).
// Once you confirm the connection works, change it back to ContentView().

struct WatchConnectionTestView: View {
    @StateObject private var phoneSession = PhoneSessionManager.shared
    @State private var sentCount = 0

    private var session: WCSession { WCSession.default }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                statusCard

                Text("Sent: \(sentCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(spacing: 12) {
                    Text("Tap a direction to send a haptic to your Watch.\nWatch out for a buzz + the screen updating to \"Last: ...\"")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        directionButton(.left)
                        directionButton(.up)
                        directionButton(.down)
                        directionButton(.right)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Watch Connection Test")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow("WCSession supported", WCSession.isSupported())
            statusRow("Watch paired", session.isPaired)
            statusRow("Watch app installed", session.isWatchAppInstalled)
            statusRow("Reachable now", phoneSession.isWatchReachable)
            HStack {
                Text("Activation state")
                Spacer()
                Text(activationStateLabel)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func statusRow(_ label: String, _ value: Bool) -> some View {
        HStack {
            Text(label)
            Spacer()
            Image(systemName: value ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(value ? .green : .red)
        }
    }

    private var activationStateLabel: String {
        switch session.activationState {
        case .activated: return "activated"
        case .inactive: return "inactive"
        case .notActivated: return "not activated"
        @unknown default: return "unknown"
        }
    }

    private func directionButton(_ direction: PhoneSessionManager.HapticDirection) -> some View {
        Button {
            phoneSession.sendHaptic(direction)
            sentCount += 1
        } label: {
            Text(direction.rawValue.capitalized)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
        }
        .buttonStyle(.bordered)
    }
}

#Preview {
    WatchConnectionTestView()
}