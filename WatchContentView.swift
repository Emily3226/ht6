import SwiftUI

struct WatchContentView: View {
    @StateObject private var session = WatchSessionManager.shared

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.walk")
                .font(.largeTitle)
            Text("Cane Companion")
                .font(.headline)
            Text("Last: \(session.lastDirection)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}
