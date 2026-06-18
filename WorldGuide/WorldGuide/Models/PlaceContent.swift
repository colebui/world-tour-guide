import Foundation

/// Tour-guide content for a place, as returned by the backend.
/// Mirrors the schema in prompts/place_content_prompt.md. Optional sections are
/// nil when the place didn't warrant them.
struct PlaceContent: Codable, Identifiable {
    var id: String { placeId }

    let placeId: String
    let name: String
    let tone: String?
    let summary: String
    let tourGuideIntro: String
    let notificationBlurb: String?
    let notifyWorthy: Bool?
    let richnessScore: Int?
    let tags: [String]?

    // Optional rich sections
    let history: String?
    let funFacts: [String]?
    let stories: [Story]?
    let details: [Detail]?
    let significance: String?
    let visitingTips: [String]?

    let confidence: String?
    let photoQueries: [String]?
    let photos: [Photo]?

    struct Story: Codable, Hashable {
        let title: String
        let body: String
    }

    struct Detail: Codable, Hashable {
        let heading: String
        let body: String
    }

    struct Photo: Codable, Hashable, Identifiable {
        var id: String { url }
        let url: String
        let source: String?
        let attribution: String?
        let license: String?
    }

    enum CodingKeys: String, CodingKey {
        case placeId = "place_id"
        case name, tone, summary
        case tourGuideIntro = "tour_guide_intro"
        case notificationBlurb = "notification_blurb"
        case notifyWorthy = "notify_worthy"
        case richnessScore = "richness_score"
        case tags, history
        case funFacts = "fun_facts"
        case stories, details, significance
        case visitingTips = "visiting_tips"
        case confidence
        case photoQueries = "photo_queries"
        case photos
    }
}

/// Envelope returned by the `getPlaceContent` function: { source, content }.
struct ContentResponse: Codable {
    let source: String   // "cache" or "generated"
    let content: PlaceContent
}
