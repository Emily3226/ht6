import Foundation

final class CaneConnection: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    var onMessage: ((CaneMessage) -> Void)?

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
                   let event = try? JSONDecoder().decode(CaneMessage.self, from: data) {
                    self?.onMessage?(event)
                }
                self?.listen() // keep listening for the next message
            case .failure(let error):
                print("Cane connection error: \(error.localizedDescription)")
            }
        }
    }

    // Used by the on-demand "what's around me" button to ask the
    // backend for a fresh, broader scene scan.
    func sendCommand(_ command: String) {
        let payload = ["command": command]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { error in
            if let error {
                print("Failed to send command: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }
}
