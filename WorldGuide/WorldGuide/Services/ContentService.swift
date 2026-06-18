import Foundation
import CoreLocation

/// Calls our backend `getPlaceContent` function, which returns cached content or
/// generates it on a cache miss. The OpenAI key lives only on the backend.
struct ContentService {
    enum ContentError: Error { case badResponse }

    func content(for place: Place, locality: String?) async throws -> PlaceContent {
        let url = URL(string: Secrets.backendURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload: [String: Any] = [
            "place_id": place.id,
            "name": place.name,
            "types": place.types,
            "lat": place.coordinate.latitude,
            "lng": place.coordinate.longitude,
            "locality": locality ?? ""
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ContentError.badResponse
        }

        return try JSONDecoder().decode(ContentResponse.self, from: data).content
    }
}
