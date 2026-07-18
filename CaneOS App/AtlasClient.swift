import Foundation

/// HTTP client for the MongoDB Atlas Data API v1.
///
/// Fill in the three values in Config.swift, then this client handles all
/// CRUD against your Atlas cluster with no extra SDK.
///
/// Setup:
/// 1. In MongoDB Atlas → App Services → create an App.
/// 2. Enable the Data API, generate an API key.
/// 3. Paste the endpoint URL, key, and cluster name into Config.swift.
final class AtlasClient {
    static let shared = AtlasClient()
    private init() {}

    private let database = "cane_os"

    // MARK: - Public API

    func insertOne(collection: String, document: [String: Any]) async throws {
        _ = try await post("insertOne", collection: collection,
                           body: ["document": document])
    }

    func insertMany(collection: String, documents: [[String: Any]]) async throws {
        guard !documents.isEmpty else { return }
        _ = try await post("insertMany", collection: collection,
                           body: ["documents": documents])
    }

    func find(collection: String,
              filter: [String: Any],
              sort: [String: Any]? = nil) async throws -> [[String: Any]] {
        var body: [String: Any] = ["filter": filter]
        if let sort { body["sort"] = sort }
        let data = try await post("find", collection: collection, body: body)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["documents"] as? [[String: Any]] ?? []
    }

    func replaceOne(collection: String,
                    filter: [String: Any],
                    replacement: [String: Any]) async throws {
        _ = try await post("replaceOne", collection: collection, body: [
            "filter": filter, "replacement": replacement, "upsert": true
        ])
    }

    func deleteOne(collection: String, filter: [String: Any]) async throws {
        _ = try await post("deleteOne", collection: collection,
                           body: ["filter": filter])
    }

    func deleteMany(collection: String, filter: [String: Any]) async throws {
        _ = try await post("deleteMany", collection: collection,
                           body: ["filter": filter])
    }

    // MARK: - Private

    private func post(_ action: String, collection: String,
                      body: [String: Any]) async throws -> Data {
        guard !Config.atlasDataAPIURL.isEmpty, !Config.atlasAPIKey.isEmpty else {
            throw AtlasError.notConfigured
        }
        guard let url = URL(string: "\(Config.atlasDataAPIURL)/api/db") else {
            throw AtlasError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.atlasAPIKey, forHTTPHeaderField: "api-key")
        var full = body
        full["action"]     = action
        full["dataSource"] = Config.atlasDataSource
        full["database"]   = database
        full["collection"] = collection
        request.httpBody = try JSONSerialization.data(withJSONObject: full)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[Atlas] error body: \(body)")
            throw AtlasError.httpError
        }
        return data
    }

    enum AtlasError: LocalizedError {
        case notConfigured, invalidURL, httpError
        var errorDescription: String? {
            switch self {
            case .notConfigured: "Atlas API URL or key not set in Config.swift"
            case .invalidURL:    "Invalid Atlas endpoint URL"
            case .httpError:     "Atlas API returned an error — check the console for the response body"
            }
        }
    }
}
