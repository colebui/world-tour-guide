import Foundation
import CoreLocation
import MapKit

struct TransitRoute {
    let polyline: MKPolyline
    let summary: String       // e.g. "23 min · Bus 42 → Métro 6"
    let durationText: String  // e.g. "23 min"
}

/// Transit directions via the Google **Routes API** (the modern replacement for the legacy
/// Directions API). Returns a polyline drawn on the Apple map plus a short summary.
/// Requires the "Routes API" enabled on the Google key.
struct DirectionsService {
    enum DirectionsError: Error { case badResponse, noRoute }

    func transitRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> TransitRoute {
        let url = URL(string: "https://routes.googleapis.com/directions/v2:computeRoutes")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Secrets.googlePlacesKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(
            "routes.duration,routes.polyline.encodedPolyline,routes.legs.steps.transitDetails",
            forHTTPHeaderField: "X-Goog-FieldMask"
        )
        if let bundleID = Bundle.main.bundleIdentifier {
            request.setValue(bundleID, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
        }

        let body: [String: Any] = [
            "origin": ["location": ["latLng": ["latitude": from.latitude, "longitude": from.longitude]]],
            "destination": ["location": ["latLng": ["latitude": to.latitude, "longitude": to.longitude]]],
            "travelMode": "TRANSIT"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DirectionsError.badResponse
        }

        let decoded = try JSONDecoder().decode(RoutesResponse.self, from: data)
        guard let route = decoded.routes?.first else { throw DirectionsError.noRoute }

        let coords = Self.decodePolyline(route.polyline.encodedPolyline)
        let polyline = MKPolyline(coordinates: coords, count: coords.count)

        let lines = (route.legs ?? [])
            .flatMap { $0.steps ?? [] }
            .compactMap { $0.transitDetails?.transitLine.nameShort ?? $0.transitDetails?.transitLine.name }
        let durationText = Self.formatDuration(route.duration)
        let summary = lines.isEmpty ? durationText : "\(durationText) · \(lines.joined(separator: " → "))"
        return TransitRoute(polyline: polyline, summary: summary, durationText: durationText)
    }

    // MARK: - Routes API DTOs

    private struct RoutesResponse: Decodable {
        let routes: [Route]?
        struct Route: Decodable {
            let duration: String?          // e.g. "1234s"
            let polyline: Poly
            let legs: [Leg]?
        }
        struct Poly: Decodable { let encodedPolyline: String }
        struct Leg: Decodable { let steps: [Step]? }
        struct Step: Decodable { let transitDetails: TransitDetails? }
        struct TransitDetails: Decodable { let transitLine: TransitLine }
        struct TransitLine: Decodable { let name: String?; let nameShort: String? }
    }

    private static func formatDuration(_ value: String?) -> String {
        guard let value, let seconds = Double(value.replacingOccurrences(of: "s", with: "")) else { return "" }
        let minutes = max(1, Int(seconds / 60))
        return "\(minutes) min"
    }

    // MARK: - Google encoded-polyline decode

    static func decodePolyline(_ str: String) -> [CLLocationCoordinate2D] {
        var coords: [CLLocationCoordinate2D] = []
        var lat = 0, lng = 0
        var index = str.startIndex
        let end = str.endIndex

        func nextValue() -> Int {
            var result = 0, shift = 0, byte: Int
            repeat {
                byte = Int(str[index].asciiValue ?? 63) - 63
                index = str.index(after: index)
                result |= (byte & 0x1f) << shift
                shift += 5
            } while byte >= 0x20 && index < end
            return (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        }

        while index < end {
            lat += nextValue()
            guard index < end else { break }
            lng += nextValue()
            coords.append(CLLocationCoordinate2D(latitude: Double(lat) / 1e5, longitude: Double(lng) / 1e5))
        }
        return coords
    }
}
