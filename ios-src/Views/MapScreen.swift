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

    // Track the visible map area so we can offer "Search this area" after a pan.
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var lastSearchedCenter: CLLocationCoordinate2D?

    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Map(position: $camera, selection: $selectedID) {
            UserAnnotation()
            ForEach(vm.places) { place in
                Marker(place.name, systemImage: "mappin", coordinate: place.coordinate)
                    .tag(place.id)
            }
            if let route = vm.route {
                MapPolyline(route.polyline).stroke(.blue, lineWidth: 5)
            }
        }
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .overlay(alignment: .top) { topBar }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
        }
        .onAppear { location.requestPermission() }
        .onChange(of: location.location) { _, newValue in
            guard let coord = newValue?.coordinate else { return }
            vm.userLocation = coord
            guard !didLoadNearby else { return }
            didLoadNearby = true
            search(center: coord, radius: 500)
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
            } else if movedEnough {
                searchAreaButton
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: movedEnough)
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

    private var searchAreaButton: some View {
        Button {
            guard let region = visibleRegion else { return }
            let radius = min(max(region.span.latitudeDelta * 111_000 / 2, 300), 5_000)
            search(center: region.center, radius: radius)
        } label: {
            Label("Search this area", systemImage: "arrow.clockwise")
                .font(.subheadline.bold())
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 4, y: 2)
        }
    }

    // MARK: - Actions

    private func goToSearchResult(_ place: Place) {
        searchFocused = false
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

    /// True once the map center has drifted far enough from the last search to be worth re-querying.
    private var movedEnough: Bool {
        guard let region = visibleRegion, let last = lastSearchedCenter else { return false }
        let current = CLLocation(latitude: region.center.latitude, longitude: region.center.longitude)
        let previous = CLLocation(latitude: last.latitude, longitude: last.longitude)
        let threshold = max(250, region.span.latitudeDelta * 111_000 * 0.3)
        return current.distance(from: previous) > threshold
    }

    private func search(center: CLLocationCoordinate2D, radius: Double) {
        lastSearchedCenter = center
        Task { await vm.loadNearby(latitude: center.latitude, longitude: center.longitude, radius: radius) }
    }
}
