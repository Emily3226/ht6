import Foundation

// Generic WebSocket client for talking to the CaneOS backend. Each channel
// (/ws/haptics, /ws/hazards, /ws/status) gets its own instance,
// parameterized by its own strict message type, so the flows can never
// cross-decode into each other and each can be handled with its own latency
// characteristics (haptics: immediate/unthrottled; hazards: richer
// processing is fine).
//
// Auto-reconnects: if the server isn't up yet at app launch, or restarts
// mid-session, the connection retries every few seconds until it's back --
// the app never needs relaunching just because the backend bounced.
final class CaneSocketConnection<Message: Decodable>: NSObject, URLSessionWebSocketDelegate {
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlString: String?
    private var isManuallyClosed = false
    private var reconnectScheduled = false
    private lazy var session = URLSession(configuration: .default,
                                          delegate: self,
                                          delegateQueue: nil)

    var onMessage: ((Message) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private let reconnectDelay: TimeInterval = 3

    func connect(to urlString: String) {
        self.urlString = urlString
        isManuallyClosed = false
        open()
    }

    private func open() {
        guard let urlString, let url = URL(string: urlString) else { return }
        reconnectScheduled = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()
        listen()
    }

    private func scheduleReconnect() {
        guard !isManuallyClosed, !reconnectScheduled else { return }
        reconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            guard let self, !self.isManuallyClosed else { return }
            self.open()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        DispatchQueue.main.async { self.onConnectionChange?(true) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        DispatchQueue.main.async { self.onConnectionChange?(false) }
        scheduleReconnect()
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
                // Covers both "server not up yet at launch" and "server
                // dropped mid-session" -- keep retrying until it's back.
                self.scheduleReconnect()
            }
        }
    }

    // Used by the on-demand "what's around me" flows to ask the backend for
    // a fresh, broader scene scan. Only meaningful on the /ws/hazards socket.
    func sendCommand(_ command: String) {
        send(["command": command])
    }

    /// Sends an arbitrary JSON object as a text frame.
    func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { error in
            if let error {
                print("Failed to send payload: \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        isManuallyClosed = true
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }
}
