import Foundation

// Hackathon speed: these live here as placeholders. Before pushing to a
// shared repo, move real values into a Config.xcconfig or a plist that's
// in .gitignore -- don't commit live API keys or the Twilio auth token.
enum Config {
    static let elevenLabsAPIKey = "sk_b76338a441208f571c1e8c1afcc05e43f6de53a8957c0450"
    static let elevenLabsVoiceId = "GZ4PpFJV8ikEGUtBrjK7"

    static let resendAPIKey = "re_KwajjgpJ_2BiJhDG4MX3VD7krDQpE5ZhZ"
    static let resendFromEmail = "emilyzhang6322@gmail.com"

    // Conversational memory for the on-demand "what's around me" thread.
    static let backboardAPIKey = "espr_t9B-Hs7_YEqKyMmY3ODFbJI2gbDlQaCF6ii71A52Ua0"
    // Python pipeline server (backend/pipeline, `python -m pipeline.main`).
    // IP = the Mac running the server (it prints this on startup); port 8765
    // is the server's DEFAULT_PORT. Phone and Mac must be on the same network.
    static let hapticsWebSocketURL = "ws://172.20.10.5:8765/ws/haptics"
    static let hazardsWebSocketURL = "ws://172.20.10.5:8765/ws/hazards"
    static let statusWebSocketURL  = "ws://172.20.10.5:8765/ws/status"
    // Same server, HTTP side — used by the Settings "simulate event" button.
    static let pipelineBaseURL     = "http://172.20.10.5:8765"

    // MARK: - MongoDB Atlas (via our Vercel proxy)
    // MongoDB sunset the hosted Atlas Data API, so backend/api/db.js (deployed
    // at the URL below) proxies CRUD + aggregation to the Atlas cluster using
    // the official Node driver. The api-key is the pre-login fallback; once
    // signed in, requests are authenticated with the user's Auth0 ID token,
    // which the backend verifies against Auth0's JWKS.
    static let atlasDataAPIURL = "https://caneos-api.vercel.app"
    static let atlasAPIKey     = "95b1cce7eaff252b418121729037beaeba331a30fe16f894"
    static let atlasDataSource = "CaneOS"

    // Used by BackendClient (route-style API: /api/sos, /api/incidents,
    // /api/contacts). Same Vercel deployment + key as the Atlas proxy above.
    // NOTE: those routes aren't deployed yet — BackendClient callers all
    // swallow failures (try?), so this stays inert until the routes land.
    static let backendAPIBaseURL = "https://caneos-api.vercel.app"
    static let backendAPIKey     = "95b1cce7eaff252b418121729037beaeba331a30fe16f894"
}
