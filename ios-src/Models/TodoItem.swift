import Foundation
import CoreLocation

/// A place saved into a to-do list.
struct TodoItem: Codable, Identifiable, Hashable {
    let id: String          // Google place_id
    let name: String
    let lat: Double
    let lng: Double
    let types: [String]
    var isDone: Bool

    init(place: Place) {
        id = place.id
        name = place.name
        lat = place.coordinate.latitude
        lng = place.coordinate.longitude
        types = place.types
        isDone = false
    }

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
