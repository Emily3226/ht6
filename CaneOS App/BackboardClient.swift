import Foundation

// Backboard's Python/JS SDKs wrap this same REST endpoint -- there's no
// Swift SDK, but the plain HTTP call works fine. NOTE: field names below
// (thread_id, memory, Authorization header shape) are assembled from
// Backboard's public docs -- double check the exact request/response
// schema at docs.backboard.io before relying on this for the event,
// since I don't have first-hand confirmation of every field name.
final class BackboardClient {
    private let apiKey: String
    private var threadId: String?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    struct Response: Decodable {
        let threadId: String
        let message: String

        enum CodingKeys: String, CodingKey {
            case threadId = "thread_id"
            case message
        }
    }

    func send(text: String) async throws -> String {
        let url = URL(string: "https://app.backboard.io/api/threads/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = ["message": text, "memory": "Auto"]
        if let threadId {
            body["thread_id"] = threadId // continues the same conversation
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        threadId = decoded.threadId // remember for the next call
        return decoded.message
    }
}
