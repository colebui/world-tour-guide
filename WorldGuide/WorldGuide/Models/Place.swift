import Foundation
import CoreLocation
import SwiftUI

/// A nearby point of interest from Google Places. `id` is the Google `place_id`,
/// which is also our backend cache key.
struct Place: Identifiable {
    let id: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let types: [String]
    var address: String? = nil

    /// True for cities / regions (vs. a specific POI we can open a guide for).
    var isArea: Bool {
        let areaTypes: Set<String> = [
            "locality", "sublocality", "administrative_area_level_1",
            "administrative_area_level_2", "administrative_area_level_3",
            "country", "political", "postal_code", "neighborhood"
        ]
        return types.contains { areaTypes.contains($0) }
    }

    var category: PlaceCategory { PlaceCategory.from(types: types) }
    var markerSymbol: String { category.symbol }
    var markerTint: Color { category.tint }
}

/// Broad place category used to pick a distinct map-pin icon + color.
enum PlaceCategory {
    case monument, museum, religious, park, nature, food, attraction, other

    static func from(types: [String]) -> PlaceCategory {
        let t = Set(types)
        func has(_ values: String...) -> Bool { values.contains { t.contains($0) } }
        // Order matters: most specific / tour-worthy first.
        if has("historical_landmark", "monument", "cultural_landmark", "historical_place") { return .monument }
        if has("museum", "art_gallery") { return .museum }
        if has("church", "mosque", "synagogue", "hindu_temple", "place_of_worship") { return .religious }
        if has("park", "national_park") { return .park }
        if has("zoo", "aquarium") { return .nature }
        if has("restaurant", "cafe", "bakery", "bar", "food") { return .food }
        if has("tourist_attraction", "amusement_park") { return .attraction }
        return .other
    }

    var symbol: String {
        switch self {
        case .monument: return "building.columns.fill"
        case .museum: return "paintpalette.fill"
        case .religious: return "building.2.fill"
        case .park: return "tree.fill"
        case .nature: return "pawprint.fill"
        case .food: return "fork.knife"
        case .attraction: return "star.fill"
        case .other: return "mappin"
        }
    }

    var tint: Color {
        switch self {
        case .monument: return .brown
        case .museum: return .purple
        case .religious: return .indigo
        case .park: return .green
        case .nature: return .teal
        case .food: return .red
        case .attraction: return .blue
        case .other: return .red
        }
    }
}

extension Place: Equatable, Hashable {
    static func == (lhs: Place, rhs: Place) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
