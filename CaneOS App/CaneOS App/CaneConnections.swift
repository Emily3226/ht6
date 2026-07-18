import Foundation

// Generic WebSocket client for talking to the CaneOS backend. Each channel
// (/ws/haptics, /ws/hazards) gets its own instance, parameterized by its own
// strict message type, so the two flows can never cross-decode into each
// other and each can be handled with its own latency characteristics
// (haptics: immediate/unthrottled; hazards: richer processing is fine).
final class CaneSocketConnection<Message: Decodable>: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    var onMessage: ((Message) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    func connect(to urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        listen()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { self.onConnectionChange?(true) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { self.onConnectionChange?(false) }
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message,
                   let data = text.data(using: .utf8),
                   let event = try? JSONDecoder().decode(Message.self, from: data) {
                    // Dispatched straight through with no intermediate queueing/
                    // batching -- each decoded message is handed to its
                    // consumer as soon as it arrives.
                    self.onMessage?(event)
                }
                self.listen()
            case .failure(let error):
                print("Cane connection error: \(error.localizedDescription)")
                DispatchQueue.main.async { self.onConnectionChange?(false) }
            }
        }
    }

    // Used by the on-demand "what's around me" button to ask the backend for
    // a fresh, broader scene scan. Only meaningful on the /ws/hazards socket.
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