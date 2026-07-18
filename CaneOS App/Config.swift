import Foundation

// Hackathon speed: these live here as placeholders. Before pushing to a
// shared repo, move real values into a Config.xcconfig or a plist that's
// in .gitignore -- don't commit live API keys or the Twilio auth token.
enum Config {
    static let elevenLabsAPIKey = "YOUR_ELEVENLABS_API_KEY"
    static let elevenLabsVoiceId = "YOUR_ELEVENLABS_VOICE_ID"

    static let backboardAPIKey = "YOUR_BACKBOARD_API_KEY"

    // Twilio: fine for a hackathon demo embedded client-side. For anything
    // beyond the demo, move SMS sending behind your own backend so this
    // auth token isn't sitting inside the compiled app.
    static let twilioAccountSid = "YOUR_TWILIO_ACCOUNT_SID"
    static let twilioAuthToken = "YOUR_TWILIO_AUTH_TOKEN"
    static let twilioFromNumber = "+15555555555"

    // Update this to your Pi's actual IP on the shared network, or wire
    // up the in-app text field in ContentView instead of hardcoding it.
    static let backendWebSocketURL = "ws://192.168.1.42:8765"
}
