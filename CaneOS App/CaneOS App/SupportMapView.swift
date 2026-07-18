import SwiftUI
import MapKit
import Combine

/// Support-partner tab: a full-screen live map of the followed user's
/// location, read from the `shared_locations` collection by share code and
/// refreshed every few seconds.
struct SupportMapView: View {
    @ObservedObject var settings: AppSettings

    struct SharedLocation {
        var name: String
        var coordinate: CLLocationCoordinate2D
        var updatedAt: Date
        var sharing: Bool
    }

    @State private var shared: SharedLocation?
    @State private var camera: MapCameraPosition = .automatic
    @State private var hasCentered = false
    @State private var codeInput = ""
    // Ticks once a second so the "updated Xs ago" label stays live.
    @State private var now = Date()

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private let clockTimer   = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.caneNavy.ignoresSafeArea()
            if settings.followCode.isEmpty {
                codeEntry
            } else {
                map
            }
        }
        .onReceive(refreshTimer) { _ in Task { await refresh() } }
        .onReceive(clockTimer) { now = $0 }
        .task(id: settings.followCode) {
            hasCentered = false
            shared = nil
            await refresh()
        }
    }

    // MARK: - Map

    private var map: some View {
        ZStack(alignment: .bottom) {
            Map(position: $camera) {
                if let shared, shared.sharing {
                    Annotation(shared.name, coordinate: shared.coordinate) {
                        ZStack {
                            Circle()
                                .fill(Color.caneBlue.opacity(0.25))
                                .frame(width: 44, height: 44)
                            Circle()
                                .fill(Color.caneBlue)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(.white, lineWidth: 3))
                        }
                    }
                }
            }
            .mapStyle(.standard)
            .ignoresSafeArea(edges: .bottom)

            statusCard
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.title3)
                .foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(statusDetail)
                    .font(.caption)
                    .foregroundColor(Color(white: 0.55))
            }
            Spacer()
            Button {
                settings.followCode = ""
                codeInput = ""
            } label: {
                Text("Change code")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.caneBlue)
            }
            .accessibilityLabel("Change the share code you're following")
        }
        .padding(14)
        .background(Color.caneCard.opacity(0.96))
        .cornerRadius(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(statusTitle). \(statusDetail)")
    }

    private var statusIcon: String {
        guard let shared else { return "antenna.radiowaves.left.and.right.slash" }
        return shared.sharing ? "location.fill" : "location.slash.fill"
    }

    private var statusColor: Color {
        guard let shared else { return Color(white: 0.45) }
        return shared.sharing ? .green : .orange
    }

    private var statusTitle: String {
        guard let shared else { return "Waiting for location…" }
        return shared.sharing ? shared.name : "\(shared.name) paused sharing"
    }

    private var statusDetail: String {
        guard let shared else {
            return "Following code \(settings.followCode). Ask them to turn on location sharing in their Settings."
        }
        let seconds = Int(now.timeIntervalSince(shared.updatedAt))
        let age = seconds < 5 ? "just now"
                : seconds < 60 ? "\(seconds)s ago"
                : seconds < 3600 ? "\(seconds / 60)m ago"
                : "\(seconds / 3600)h ago"
        return shared.sharing ? "Updated \(age)" : "Last seen \(age)"
    }

    // MARK: - Code entry

    private var codeEntry: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "map.fill")
                .font(.system(size: 52))
                .foregroundColor(.caneBlue)
            Text("Follow a loved one")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text("Enter the 6-character share code shown in their CaneOS Settings under Location Sharing.")
                .font(.subheadline)
                .foregroundColor(Color(white: 0.55))
                .multilineTextAlignment(.center)

            TextField("Share code", text: $codeInput)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .multilineTextAlignment(.center)
                .padding(.vertical, 16)
                .background(Color.caneCard)
                .cornerRadius(14)
                .foregroundColor(.white)
                .onChange(of: codeInput) { _, newValue in
                    codeInput = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
                }
                .accessibilityLabel("Share code entry field")

            Button {
                settings.followCode = codeInput
            } label: {
                Text("Start Following")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(codeInput.count == 6 ? Color.caneBlue : Color(white: 0.18))
                    .foregroundColor(.white)
                    .cornerRadius(14)
            }
            .disabled(codeInput.count != 6)
            .accessibilityLabel("Start following this share code")
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
    }

    // MARK: - Atlas polling

    private func refresh() async {
        let code = settings.followCode
        guard !code.isEmpty else { return }
        guard let doc = try? await AtlasClient.shared.find(
            collection: "shared_locations",
            filter: ["shareCode": code]
        ).first else { return }

        let sharing = doc["sharing"] as? Bool ?? false
        let name = doc["name"] as? String ?? "Your loved one"
        let updatedAt = Date(timeIntervalSince1970: doc["updatedAt"] as? Double ?? 0)

        if sharing,
           let lat = doc["latitude"] as? Double,
           let lon = doc["longitude"] as? Double {
            let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            shared = SharedLocation(name: name, coordinate: coordinate,
                                    updatedAt: updatedAt, sharing: true)
            // Center on them the first time (and re-center only if the pin
            // would drift off a hands-off map).
            if !hasCentered {
                hasCentered = true
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                ))
            }
        } else {
            shared = SharedLocation(
                name: name,
                coordinate: shared?.coordinate ?? CLLocationCoordinate2D(),
                updatedAt: updatedAt,
                sharing: false
            )
        }
    }
}
