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
    let audioURL: String?
    let tier: String?

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
        case audioURL = "audio_url"
        case tier
    }
}

/// Envelope returned by the `getPlaceContent` function: { source, content }.
struct ContentResponse: Codable {
    let source: String   // "cache" or "generated"
    let content: PlaceContent
}

/// All-optional mirror of PlaceContent for rendering mid-stream snapshots. Decoding is
/// defensive: a missing or half-formed field is simply nil, never a thrown error, so a
/// partial JSON snapshot always renders whatever is present so far.
struct PartialPlaceContent {
    var name: String?
    var tone: String?
    var summary: String?
    var tourGuideIntro: String?
    var history: String?
    var funFacts: [String]?
    var stories: [PartialPair]?
    var details: [PartialPair]?
    var significance: String?
    var visitingTips: [String]?
    var photos: [PlaceContent.Photo]?
    var audioURL: String?
    var tier: String?

    /// A story (title/body) or detail (heading/body) whose parts may not have streamed in yet.
    struct PartialPair: Hashable {
        var first: String?    // title / heading
        var second: String?   // body
    }
}

extension PartialPlaceContent: Decodable {
    enum CodingKeys: String, CodingKey {
        case name, tone, summary
        case tourGuideIntro = "tour_guide_intro"
        case history
        case funFacts = "fun_facts"
        case stories, details, significance
        case visitingTips = "visiting_tips"
        case photos
        case audioURL = "audio_url"
        case tier
    }
    enum PairKeys: String, CodingKey { case title, heading, body }

    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        guard let c else { return }
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        tone = try? c.decodeIfPresent(String.self, forKey: .tone)
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        tourGuideIntro = try? c.decodeIfPresent(String.self, forKey: .tourGuideIntro)
        history = try? c.decodeIfPresent(String.self, forKey: .history)
        funFacts = (try? c.decodeIfPresent([String].self, forKey: .funFacts)) ?? nil
        significance = try? c.decodeIfPresent(String.self, forKey: .significance)
        visitingTips = (try? c.decodeIfPresent([String].self, forKey: .visitingTips)) ?? nil
        photos = (try? c.decodeIfPresent([PlaceContent.Photo].self, forKey: .photos)) ?? nil
        audioURL = try? c.decodeIfPresent(String.self, forKey: .audioURL)
        tier = try? c.decodeIfPresent(String.self, forKey: .tier)
        stories = Self.decodePairs(in: c, key: .stories, firstKey: .title)
        details = Self.decodePairs(in: c, key: .details, firstKey: .heading)
    }

    private static func decodePairs(in c: KeyedDecodingContainer<CodingKeys>,
                                    key: CodingKeys, firstKey: PairKeys) -> [PartialPair]? {
        guard var arr = try? c.nestedUnkeyedContainer(forKey: key) else { return nil }
        var pairs: [PartialPair] = []
        while !arr.isAtEnd {
            guard let obj = try? arr.nestedContainer(keyedBy: PairKeys.self) else { break }
            let first = try? obj.decodeIfPresent(String.self, forKey: firstKey)
            let second = try? obj.decodeIfPresent(String.self, forKey: .body)
            pairs.append(PartialPair(first: first ?? nil, second: second ?? nil))
        }
        return pairs
    }

    /// Build a fully-populated partial from the final strict doc (one rendering path).
    init(from full: PlaceContent) {
        name = full.name
        tone = full.tone
        summary = full.summary
        tourGuideIntro = full.tourGuideIntro
        history = full.history
        funFacts = full.funFacts
        stories = full.stories?.map { .init(first: $0.title, second: $0.body) }
        details = full.details?.map { .init(first: $0.heading, second: $0.body) }
        significance = full.significance
        visitingTips = full.visitingTips
        photos = full.photos
        audioURL = full.audioURL
        tier = full.tier
    }
}
