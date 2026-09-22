import SwiftUI
import MapKit
import CoreLocation

struct MapScreen: View {
    @StateObject private var location = LocationManager()
    @StateObject private var vm = MapViewModel()
    @StateObject private var speech = SpeechService()
    @StateObject private var todo = TodoStore()

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var selectedID: String?
    @State private var didLoadNearby = false
    @State private var detent: PresentationDetent = .fraction(0.4)

    // Track the visible map area so we can auto-refresh pins after a pan.
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var lastSearchedCenter: CLLocationCoordinate2D?
    @State private var autoSearchTask: Task<Void, Never>?
    // Recently searched areas, for overlap de-duping so panning doesn't refire calls. Capped.
    @State private var searchedAreas: [(center: CLLocationCoordinate2D, radius: Double)] = []

    @StateObject private var completer = SearchCompleter()
    @State private var searchText = ""
    @State private var suppressCompleter = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Map(position: $camera, selection: $selectedID) {
            UserAnnotation()
            ForEach(vm.places) { place in
                let saved = todo.contains(placeID: place.id)
                Marker(place.name,
                       systemImage: saved ? "bookmark.fill" : place.markerSymbol,
                       coordinate: place.coordinate)
                    .tint(saved ? .orange : place.markerTint)
                    .tag(place.id)
            }
            if let poly = vm.routePolyline {
                MapPolyline(poly).stroke(.blue, lineWidth: 5)
            }
        }
        .mapControls {
            MapCompass()
        }
        .overlay(alignment: .top) { topBar }
        .overlay(alignment: .topTrailing) {
            Button {
                recenterOnUser()
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.blue)
                    .padding(12)
                    .background(.regularMaterial, in: Circle())
                    .shadow(radius: 3, y: 1)
            }
            .padding(.trailing, 12)
            .padding(.top, 72)
            .accessibilityLabel("Show my location")
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            scheduleAutoSearch(for: context.region)
        }
        .onAppear { location.requestPermission() }
        .onChange(of: location.location) { _, newValue in
            guard let coord = newValue?.coordinate else { return }
            vm.userLocation = coord
            Task { await vm.refreshCity() }
            guard !didLoadNearby else { return }
            didLoadNearby = true
            search(center: coord, radius: 500)
        }
        .onChange(of: searchText) { _, newValue in
            if suppressCompleter { suppressCompleter = false; return }
            completer.update(query: newValue, region: visibleRegion)
            if newValue.isEmpty { vm.clearSearch() }
        }
        .onChange(of: selectedID) { _, newID in
            guard let id = newID, let place = vm.places.first(where: { $0.id == id }) else { return }
            detent = .fraction(0.4)
            Task { await vm.select(place) }
        }
        .sheet(isPresented: $vm.isSheetPresented, onDismiss: {
            selectedID = nil
            speech.stop()
            detent = .fraction(0.4)
            vm.dismiss()
        }) {
            BottomSheetView(vm: vm, speech: speech, store: todo, detent: $detent)
                .presentationDetents([.peek, .fraction(0.4), .large], selection: $detent)
                .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.4)))
                .presentationDragIndicator(.visible)
                .interactiveDismissDisabled(true)
        }
    }

    // MARK: - Top bar (search + "search this area")

    private var topBar: some View {
        VStack(spacing: 8) {
            searchField
            if !vm.searchResults.isEmpty {
                searchResultsList
            } else if !completer.suggestions.isEmpty {
                suggestionsList
            }
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: vm.searchResults.isEmpty)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search cities or places", text: $searchText)
                .focused($searchFocused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { Task { await vm.search(query: searchText) } }
            if vm.isSearching {
                ProgressView()
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    vm.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 4, y: 2)
        .padding(.horizontal)
    }

    private var searchResultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(vm.searchResults) { place in
                    Button { goToSearchResult(place) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: place.isArea ? "building.2" : "mappin.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).foregroundStyle(.primary)
                                if let address = place.address {
                                    Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                    if place.id != vm.searchResults.last?.id { Divider() }
                }
            }
        }
        .frame(maxHeight: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4, y: 2)
        .padding(.horizontal)
    }

    private var suggestionsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(completer.suggestions.prefix(8)), id: \.self) { suggestion in
                    Button { selectSuggestion(suggestion) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).foregroundStyle(.primary)
                                if !suggestion.subtitle.isEmpty {
                                    Text(suggestion.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 260)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 4, y: 2)
        .padding(.horizontal)
    }

    // MARK: - Actions

    private func selectSuggestion(_ suggestion: MKLocalSearchCompletion) {
        searchFocused = false
        completer.clear()
        let query = suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
        Task {
            await vm.search(query: query)
            if let first = vm.searchResults.first {
                goToSearchResult(first)
            }
        }
    }

    private func goToSearchResult(_ place: Place) {
        searchFocused = false
        completer.clear()
        suppressCompleter = true
        searchText = place.name
        vm.clearSearch()

        let span = place.isArea ? 0.06 : 0.012
        withAnimation {
            camera = .region(MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            ))
        }
        search(center: place.coordinate, radius: place.isArea ? 2_000 : 800)

        if !place.isArea {
            detent = .fraction(0.4)
            Task { await vm.select(place) }
        }
    }

    /// Debounces a camera move, then refreshes pins for the new area unless it overlaps a recent search.
    private func scheduleAutoSearch(for region: MKCoordinateRegion) {
        autoSearchTask?.cancel()
        autoSearchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            let radius = min(max(region.span.latitudeDelta * 111_000 / 2, 300), 5_000)
            guard shouldSearch(center: region.center, radius: radius) else { return }
            search(center: region.center, radius: radius)
        }
    }

    /// True if the new area isn't substantially covered by a recently searched one.
    private func shouldSearch(center: CLLocationCoordinate2D, radius: Double) -> Bool {
        let point = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return !searchedAreas.contains { prev in
            let p = CLLocation(latitude: prev.center.latitude, longitude: prev.center.longitude)
            return point.distance(from: p) < prev.radius * 0.5   // >50% overlap → already have these pins
        }
    }

    private func search(center: CLLocationCoordinate2D, radius: Double) {
        lastSearchedCenter = center
        searchedAreas.append((center, radius))
        if searchedAreas.count > 50 { searchedAreas.removeFirst() }
        Task { await vm.loadNearby(latitude: center.latitude, longitude: center.longitude, radius: radius) }
    }

    /// Recenter the map on the user's current location.
    private func recenterOnUser() {
        withAnimation {
            if let coord = location.location?.coordinate {
                camera = .region(MKCoordinateRegion(
                    center: coord,
                    span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                ))
            } else {
                camera = .userLocation(fallback: .automatic)
            }
        }
    }
}
