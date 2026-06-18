import Foundation
import CoreLocation

/// A place saved to the user's to-do list, grouped by city.
struct TodoItem: Codable, Identifiable, Hashable {
    let id: String          // Google place_id
    let name: String
    let lat: Double
    let lng: Double
    let types: [String]
    var city: String
    var isDone: Bool
    var order: Int

    /// Rebuilds a `Place` so saved items can be reopened via `MapViewModel.select`.
    var place: Place {
        Place(
            id: id,
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
            types: types
        )
    }
}
