import Foundation
import CoreLocation

/// Fetches nearby POIs from the Google Places API (Nearby Search, v1).
/// Uses the bundle-restricted key in Secrets — this is the one Google call we make
/// directly from the app; everything else goes through our backend.
struct PlacesService {
    enum PlacesError: Error { case badResponse }

    func nearby(latitude: Double, longitude: Double, radius: Double = 500) async throws -> [Place] {
        let url = URL(string: "https://places.googleapis.com/v1/places:searchNearby")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.googlePlacesKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.id,places.displayName,places.location,places.types",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        // Lets you restrict the API key to this app's iOS bundle ID in Google Cloud.
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        let body: [String: Any] = [
            "maxResultCount": 20,
            "locationRestriction": [
                "circle": [
                    "center": ["latitude": latitude, "longitude": longitude],
                    "radius": radius
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PlacesError.badResponse
        }

        let decoded = try JSONDecoder().decode(NearbyResponse.self, from: data)
        return decoded.places?.compactMap { $0.toPlace() } ?? []
    }

    /// Text search for cities or specific places (e.g. "Rome", "Colosseum").
    func searchText(_ query: String) async throws -> [Place] {
        let url = URL(string: "https://places.googleapis.com/v1/places:searchText")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.googlePlacesKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "places.id,places.displayName,places.location,places.types,places.formattedAddress",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["textQuery": query])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PlacesError.badResponse
        }
        let decoded = try JSONDecoder().decode(NearbyResponse.self, from: data)
        return decoded.places?.compactMap { $0.toPlace() } ?? []
    }

    // MARK: - Google Places DTOs

    private struct NearbyResponse: Decodable {
        let places: [PlaceDTO]?
    }

    private struct PlaceDTO: Decodable {
        let id: String
        let displayName: DisplayName?
        let location: LatLng?
        let types: [String]?
        let formattedAddress: String?

        struct DisplayName: Decodable { let text: String }
        struct LatLng: Decodable { let latitude: Double; let longitude: Double }

        func toPlace() -> Place? {
            guard let name = displayName?.text, let loc = location else { return nil }
            return Place(
                id: id,
                name: name,
                coordinate: CLLocationCoordinate2D(latitude: loc.latitude, longitude: loc.longitude),
                types: types ?? [],
                address: formattedAddress
            )
        }
    }
}
