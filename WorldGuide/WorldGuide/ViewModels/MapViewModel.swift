import Foundation
import Combine
import CoreLocation
import MapKit

@MainActor
final class MapViewModel: ObservableObject {
    @Published var places: [Place] = []
    @Published var selectedPlace: Place?
    @Published var content: PlaceContent?
    @Published var displayContent: PartialPlaceContent?
    @Published var isStreaming = false
    @Published var isLoadingContent = false
    @Published var errorMessage: String?
    @Published var isSheetPresented = false
    @Published var recentPlaces: [Place] = []
    @Published var searchResults: [Place] = []
    @Published var isSearching = false
    @Published var routePolyline: MKPolyline?
    @Published var routeInfo: String?
    @Published var transportMode: TransportMode = .walk
    @Published var routeOptions: [TransportMode: RouteOption] = [:]
    @Published var computingModes: Set<TransportMode> = []
    @Published var currentCity: String?
    @Published var showPaywall = false   // set when the backend reports the free limit is reached (402)
    var userLocation: CLLocationCoordinate2D?

    /// A fully-computed route for one mode, cached so picking it is instant and bills nothing extra.
    struct RouteOption {
        let polyline: MKPolyline
        let info: String   // full summary (with transit line names)
        let eta: String    // short time, e.g. "12 min"
    }

    private let placesService = PlacesService()
    private let contentService = ContentService()
    private let directionsService = DirectionsService()

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

    /// Reverse-geocodes the user's location into a city name (for the new-list default), using the
    /// iOS 26 MapKit geocoding API (CLGeocoder is deprecated).
    func refreshCity() async {
        guard let loc = userLocation, currentCity == nil else { return }
        let location = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return }
        if let items = try? await request.mapItems,
           let city = items.first?.addressRepresentations?.cityWithContext {
            currentCity = city
        }
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
        routePolyline = nil
        routeInfo = nil
        routeOptions = [:]
        computingModes = []
        content = nil
        displayContent = nil
        errorMessage = nil
        showPaywall = false
        isLoadingContent = true
        isStreaming = true
        addToRecent(place)
        defer { isLoadingContent = false; isStreaming = false }
        do {
            for try await event in contentService.stream(for: place, locality: nil) {
                guard selectedPlace?.id == place.id else { return }  // user moved on
                switch event {
                case .partial(let partial):
                    isLoadingContent = false
                    displayContent = partial
                case .complete(let full):
                    content = full
                    displayContent = PartialPlaceContent(from: full)
                }
            }
        } catch let error as ContentService.ContentError {
            switch error {
            case .freeLimitReached:
                showPaywall = true
                errorMessage = "You've used your free days. Subscribe to keep exploring."
            case .rateLimited:
                errorMessage = "You're going a bit fast — try again in a moment."
            case .unauthorized:
                errorMessage = "Couldn't verify your session. Please try again."
            case .badResponse:
                errorMessage = "Couldn't load a guide for \(place.name)."
            }
            print("select error: \(error)")
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
        displayContent = nil
        isStreaming = false
        errorMessage = nil
        routePolyline = nil
        routeInfo = nil
        routeOptions = [:]
        computingModes = []
    }

    // MARK: - Directions

    /// Computes a route to `place` in the given mode and stores its polyline + summary.
    /// Walk/drive use Apple MKDirections (free); transit uses the Google Routes API.
    func computeRoute(to place: Place, mode: TransportMode) async {
        transportMode = mode
        routePolyline = nil
        routeInfo = nil
        if let option = await routeOption(to: place, mode: mode) {
            routePolyline = option.polyline
            routeInfo = option.info
        } else {
            routeInfo = mode == .transit ? "Transit route unavailable" : "Route unavailable"
        }
    }

    /// Computes all modes' routes concurrently and caches them so the chooser can show ETAs and
    /// selecting a mode is instant (no extra network call). Transit hits Google once here.
    func computeRouteOptions(to place: Place) async {
        computingModes = Set(TransportMode.allCases)
        await withTaskGroup(of: (TransportMode, RouteOption?).self) { group in
            for mode in TransportMode.allCases {
                group.addTask { [weak self] in
                    (mode, await self?.routeOption(to: place, mode: mode) ?? nil)
                }
            }
            for await (mode, option) in group {
                if let option { routeOptions[mode] = option }
                computingModes.remove(mode)
            }
        }
    }

    /// Applies an already-computed route for `mode` from the cache (no network).
    func applyMode(_ mode: TransportMode) {
        transportMode = mode
        guard let option = routeOptions[mode] else { return }
        routePolyline = option.polyline
        routeInfo = option.info
    }

    /// Shared per-mode computation used by both the single-route and options flows.
    private func routeOption(to place: Place, mode: TransportMode) async -> RouteOption? {
        guard let from = userLocation else { return nil }
        if mode.usesApple {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: from))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
            request.transportType = mode.mkType
            do {
                let response = try await MKDirections(request: request).calculate()
                guard let route = response.routes.first else { return nil }
                let eta = "\(max(1, Int(route.expectedTravelTime / 60))) min"
                let info = "\(eta) · \(MKDistanceFormatter().string(fromDistance: route.distance))"
                return RouteOption(polyline: route.polyline, info: info, eta: eta)
            } catch {
                print("route error: \(error)")
                return nil
            }
        } else {
            do {
                let transit = try await directionsService.transitRoute(from: from, to: place.coordinate)
                return RouteOption(polyline: transit.polyline, info: transit.summary, eta: transit.durationText)
            } catch {
                print("transit route error: \(error)")
                return nil
            }
        }
    }

    /// Hands off to Apple Maps for turn-by-turn navigation in the given mode.
    func openInMaps(_ place: Place, mode: TransportMode) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        item.name = place.name
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: mode.launchMode])
    }
}
