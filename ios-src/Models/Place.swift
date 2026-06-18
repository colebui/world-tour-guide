import Foundation
import CoreLocation

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
}

extension Place: Equatable, Hashable {
    static func == (lhs: Place, rhs: Place) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
