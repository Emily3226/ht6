import Foundation

struct ObstacleEvent: Decodable {
    let direction: String   // "left" | "right" | "up" | "down"
    let distanceCm: Double
    let label: String?      // optional description, e.g. "open cabinet door"
}

final class CaneConnection: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    var onObstacle: ((ObstacleEvent) -> Void)?

    // Point this at the UNO Q's IP on the shared WiFi/hotspot, e.g. ws://192.168.1.42:8765
    func connect(to urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        listen()
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(ObstacleEvent.self, from: data) {
                    self?.onObstacle?(event)
                }
                self?.listen() // keep listening for the next message
            case .failure(let error):
                print("Cane connection error: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }
}
