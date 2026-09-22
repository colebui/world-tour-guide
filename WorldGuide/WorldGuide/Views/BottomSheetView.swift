import SwiftUI

extension PresentationDetent {
    /// The minimized "peek" bar height.
    static let peek = PresentationDetent.height(96)
}

/// The Google-Maps-style sheet. Renders a compact bar when minimized to the peek detent,
/// otherwise the full tabbed content: Guide / Recent / Explore / Saved.
struct BottomSheetView: View {
    @ObservedObject var vm: MapViewModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var store: TodoStore
    @EnvironmentObject var auth: AuthService
    @Binding var detent: PresentationDetent

    enum Tab: Hashable { case guide, recent, explore, saved }
    @State private var tab: Tab = .guide
    @State private var showAuth = false
    @AppStorage("ttsMuted") private var muted = false

    var body: some View {
        if detent == .peek {
            compactBar
        } else {
            fullContent
        }
    }

    // MARK: - Compact peek bar

    private var compactBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.selectedPlace?.name ?? "Guide")
                    .font(.headline).lineLimit(1)
                if let summary = vm.routeInfo {
                    Text(summary).font(.caption).foregroundStyle(.blue)
                } else if let summary = vm.displayContent?.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let place = vm.selectedPlace {
                Menu {
                    ForEach(TransportMode.allCases) { mode in
                        Button {
                            Task { await vm.computeRoute(to: place, mode: mode) }
                        } label: {
                            Label(mode.label, systemImage: mode.symbol)
                        }
                    }
                    Divider()
                    Button {
                        vm.openInMaps(place, mode: vm.transportMode)
                    } label: {
                        Label("Open in Maps instead", systemImage: "arrow.up.forward.app")
                    }
                } label: {
                    Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                }
            }
            Button {
                speech.playGuide(audioURL: vm.displayContent?.audioURL,
                                 fallbackText: vm.displayContent?.tourGuideIntro ?? "")
            } label: {
                Image(systemName: speech.isSpeaking ? "stop.fill" : "play.fill")
            }
            .disabled(vm.displayContent?.tourGuideIntro == nil && vm.displayContent?.audioURL == nil)
        }
        .font(.title3)
        .padding(.horizontal)
        .padding(.top, 14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Full content

    private var fullContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $tab) {
                    Text("Guide").tag(Tab.guide)
                    Text("Recent").tag(Tab.recent)
                    Text("Explore").tag(Tab.explore)
                    Text("Saved").tag(Tab.saved)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)

                Divider()

                switch tab {
                case .guide:
                    guideTab
                case .recent:
                    placeList(vm.recentPlaces, emptyText: "Places you open will show up here.")
                case .explore:
                    placeList(vm.places, emptyText: "Move around the map to discover nearby places.")
                case .saved:
                    TodoView(store: store, defaultCity: vm.currentCity)
                }
            }
            .navigationDestination(for: UUID.self) { listID in
                TodoListDetailView(store: store, vm: vm, listID: listID, onOpen: open)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { withAnimation { detent = .peek } } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Minimize")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAuth = true } label: {
                        Image(systemName: auth.isSignedIn ? "person.crop.circle.fill" : "person.crop.circle")
                    }
                    .accessibilityLabel("Account")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        muted.toggle()
                        if muted {
                            speech.stop()
                        } else if !speech.isSpeaking && !speech.isPreparing {
                            // Unmuting starts the current guide immediately, like the Listen button.
                            speech.playGuide(audioURL: vm.displayContent?.audioURL,
                                             fallbackText: vm.displayContent?.tourGuideIntro ?? "")
                        }
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .accessibilityLabel(muted ? "Unmute narration" : "Mute narration")
                }
            }
            .onChange(of: vm.content?.id) { _, newID in
                guard newID != nil, !muted else { return }
                speech.playGuide(audioURL: vm.content?.audioURL,
                                 fallbackText: vm.content?.tourGuideIntro ?? "")
            }
            .sheet(isPresented: $showAuth) {
                AuthSheet().environmentObject(auth)
            }
            .sheet(isPresented: $vm.showPaywall) {
                PaywallView()
            }
        }
    }

    private var title: String {
        switch tab {
        case .guide: return vm.selectedPlace?.name ?? "Guide"
        case .recent: return "Recent"
        case .explore: return "Explore Nearby"
        case .saved: return "Saved"
        }
    }

    /// Open a place's guide from a list (Recent/Explore/Saved): switch to Guide and load it.
    private func open(_ place: Place) {
        tab = .guide
        Task { await vm.select(place) }
    }

    @ViewBuilder
    private var guideTab: some View {
        if let error = vm.errorMessage {
            ContentUnavailableView("Couldn't load guide",
                                   systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if vm.selectedPlace != nil {
            // Render the structure immediately; skeletons fill the gaps while streaming.
            PlaceDetailView(partial: vm.displayContent, isStreaming: vm.isStreaming,
                            vm: vm, speech: speech, store: store, detent: $detent)
        } else {
            ContentUnavailableView("Pick a place",
                                   systemImage: "mappin.and.ellipse",
                                   description: Text("Tap a pin on the map, or choose one from Explore."))
        }
    }

    @ViewBuilder
    private func placeList(_ places: [Place], emptyText: String) -> some View {
        if places.isEmpty {
            ContentUnavailableView("Nothing yet", systemImage: "map", description: Text(emptyText))
        } else {
            List(places) { place in
                Button {
                    open(place)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(place.name)
                        if let type = place.types.first {
                            Text(type.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}
