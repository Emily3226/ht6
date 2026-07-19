import Foundation

// The backend now speaks over TWO separate WebSocket connections instead of
// one shared one. Each has its own message shape, and each is modeled by its
// own strict Decodable type below so a malformed/out-of-spec payload on one
// channel can never be silently accepted as the other.

// MARK: - /ws/haptics
//
// IMMEDIATE HAPTIC BUZZ FLOW. Exactly 3 possible messages, one per physical
// sensor, unthrottled, immediate:
//   {"direction": "left"}
//   {"direction": "right"}
//   {"direction": "up"}
// No more, no less -- three sensors, three possible values, nothing fancier.
// Deliberately has NO other fields (no hazard_type/urgency/spoken_description) --
// that richness lives on /ws/hazards, not here.

enum HapticSensorDirection: String, Decodable, CaseIterable {
    case left, right, up
}

struct HapticMessage: Decodable {
    let direction: HapticSensorDirection
}

// MARK: - /ws/hazards
//
// AUDIO FLOW. Richer, throttled (by the backend), 4 possible `direction`
// values:
//   {"hazard_type": "...", "direction": "left" | "center" | "right" | "up",
//    "urgency": "...", "spoken_description": "..."}

enum HazardDirection: String, Decodable {
    case left, center, right, up
}

struct HazardMessage: Decodable {
    let hazardType: String
    let direction: HazardDirection
    let urgency: String
    let spokenDescription: String

    enum CodingKeys: String, CodingKey {
        case hazardType = "hazard_type"
        case direction
        case urgency
        case spokenDescription = "spoken_description"
    }
}

// MARK: - /ws/hazards channel envelope
//
// The scan-on-demand reply ("what's around me?") is not part of the
// haptics/hazards spec above, but it rides back on this same /ws/hazards
// socket, tagged with its own "type" so it doesn't get confused with an
// unsolicited hazard push. This envelope discriminates between the two so
// HazardMessage itself can stay a clean, exact match for the spec shape.
enum CaneHazardChannelEvent: Decodable {
    case hazard(HazardMessage)
    case sceneDescription(text: String)
    /// Reply to a voice question ({"question", "session_id"} sent by the
    /// app): {"answer": "<english answer>"} — spoken verbatim by ElevenLabs.
    case answer(text: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, answer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let answer = try container.decodeIfPresent(String.self, forKey: .answer) {
            self = .answer(text: answer)
        } else if let type = try container.decodeIfPresent(String.self, forKey: .type),
                  type == "scene_description" {
            let text = try container.decode(String.self, forKey: .text)
            self = .sceneDescription(text: text)
        } else {
            self = .hazard(try HazardMessage(from: decoder))
        }
    }
}

// MARK: - /ws/status
//
// SYSTEM HEALTH FLOW. Unthrottled but rare by nature -- fires only on an
// actual state transition, not on a poll/heartbeat cadence:
//   {"event": "camera_offline" | "camera_restored", "timestamp": ...}
// Kept as its own strict Decodable type/socket (rather than folded into
// /ws/hazards) since it's a different concern -- hardware health, not a
// detected obstacle -- with its own tiny two-value vocabulary.

enum CameraStatusEvent: String, Decodable {
    case cameraOffline = "camera_offline"
    case cameraRestored = "camera_restored"
}

struct StatusMessage: Decodable {
    let event: CameraStatusEvent
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case event, timestamp
    }
}