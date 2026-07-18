import Foundation

/// HTTP client for the CaneOS MongoDB Atlas backend.
///
/// MongoDB sunset the hosted Atlas Data API in Sept 2025, so this talks to
/// our own thin proxy (backend/api/db.js, deployed on Vercel) which runs the
/// official MongoDB Node driver against the Atlas cluster.
///
/// Auth: when the user is signed in, every request carries their Auth0 ID
/// token; the backend verifies it against Auth0's JWKS and scopes all
/// queries to that user server-side. The shared api-key header is the
/// pre-login / testing fallback.
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
        return Self.documents(from: data)
    }

    /// Runs a MongoDB aggregation pipeline (e.g. $facet stats, $geoNear)
    /// and returns the resulting documents.
    func aggregate(collection: String,
                   pipeline: [[String: Any]]) async throws -> [[String: Any]] {
        let data = try await post("aggregate", collection: collection,
                                  body: ["pipeline": pipeline])
        return Self.documents(from: data)
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

    private static func documents(from data: Data) -> [[String: Any]] {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["documents"] as? [[String: Any]] ?? []
    }

    private func post(_ action: String, collection: String,
                      body: [String: Any]) async throws -> Data {
        guard !Config.atlasDataAPIURL.isEmpty, !Config.atlasAPIKey.isEmpty else {
            throw AtlasError.notConfigured
        }
        // action rides in both the query string and the body so either
        // backend routing style works.
        guard let url = URL(string: "\(Config.atlasDataAPIURL)/api/db?action=\(action)") else {
            throw AtlasError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Config.atlasAPIKey, forHTTPHeaderField: "api-key")
        if let token = await AuthManager.shared.bearerToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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
            case .notConfigured: "Atlas backend URL or key not set in Config.swift"
            case .invalidURL:    "Invalid Atlas backend URL"
            case .httpError:     "Atlas backend returned an error — check the console for the response body"
            }
        }
    }
}
