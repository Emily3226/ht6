import Foundation

// The backend sends one of two message shapes over the WebSocket,
// distinguished by "type". Both share this envelope so decoding is simple.
struct CaneMessage: Decodable {
    let type: String // "hazard" | "scene_description"

    // Present when type == "hazard"
    let hazardType: String?
    let direction: String?      // "left" | "right" | "up" | "down"
    let urgency: String?        // "low" | "medium" | "high"
    let spokenDescription: String?

    // Present when type == "scene_description" (the on-demand branch)
    let text: String?

    enum CodingKeys: String, CodingKey {
        case type
        case hazardType = "hazard_type"
        case direction
        case urgency
        case spokenDescription = "spoken_description"
        case text
    }
}
