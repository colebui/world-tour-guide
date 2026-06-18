import Foundation
import Combine
import CoreLocation
import MapKit

@MainActor
final class MapViewModel: ObservableObject {
    @Published var places: [Place] = []
    @Published var selectedPlace: Place?
    @Published var content: PlaceContent?
    @Published var isLoadingContent = false
    @Published var errorMessage: String?
    @Published var isSheetPresented = false
    @Published var recentPlaces: [Place] = []
    @Published var searchResults: [Place] = []
    @Published var isSearching = false
    @Published var route: MKRoute?
    var userLocation: CLLocationCoordinate2D?

    private let placesService = PlacesService()
    private let contentService = ContentService()

    func search(query: String) async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { searchResults = []; return }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await placesService.searchText(q)
        } catch {
            searchResults = []
            print("search error: \(error)")
        }
    }

    func clearSearch() {
        searchResults = []
    }

    func loadNearby(latitude: Double, longitude: Double, radius: Double = 500) async {
        do {
            places = try await placesService.nearby(latitude: latitude, longitude: longitude, radius: radius)
        } catch {
            errorMessage = "Couldn't load nearby places."
            print("loadNearby error: \(error)")
        }
    }

    /// Called when the user taps a pin or a Recent/Explore row: fetch content for that place.
    func select(_ place: Place) async {
        selectedPlace = place
        isSheetPresented = true
        route = nil
        content = nil
        errorMessage = nil
        isLoadingContent = true
        addToRecent(place)
        defer { isLoadingContent = false }
        do {
            content = try await contentService.content(for: place, locality: nil)
        } catch {
            errorMessage = "Couldn't load a guide for \(place.name)."
            print("select error: \(error)")
        }
    }

    private func addToRecent(_ place: Place) {
        recentPlaces.removeAll { $0.id == place.id }
        recentPlaces.insert(place, at: 0)
        if recentPlaces.count > 25 { recentPlaces.removeLast() }
    }

    func dismiss() {
        isSheetPresented = false
        selectedPlace = nil
        content = nil
        errorMessage = nil
        route = nil
    }

    // MARK: - Directions

    /// Computes a walking route from the user's location to `place` and stores it for drawing.
    func computeRoute(to place: Place) async {
        guard let from = userLocation else { return }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        request.transportType = .walking
        do {
            let response = try await MKDirections(request: request).calculate()
            route = response.routes.first
        } catch {
            print("route error: \(error)")
        }
    }

    /// Hands off to Apple Maps for turn-by-turn walking navigation.
    func openInMaps(_ place: Place) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }

    /// Human-readable "12 min · 0.8 mi" for the current route, if any.
    var routeSummary: String? {
        guard let route else { return nil }
        let minutes = max(1, Int(route.expectedTravelTime / 60))
        let distance = MKDistanceFormatter().string(fromDistance: route.distance)
        return "\(minutes) min · \(distance)"
    }
}
