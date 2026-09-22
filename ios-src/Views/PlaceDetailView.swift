import SwiftUI

/// Renders whatever sections the content contains, in a fixed order. While streaming, the
/// always-present fields (summary, intro) show shimmer skeletons until they arrive; optional
/// sections pop in as they stream; photos arrive last.
struct PlaceDetailView: View {
    let partial: PartialPlaceContent?
    let isStreaming: Bool
    @ObservedObject var vm: MapViewModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var store: TodoStore
    @Binding var detent: PresentationDetent

    @State private var showSaveDialog = false
    @State private var showNewListAlert = false
    @State private var newListName = ""
    @State private var showDirChooser = false

    private var intro: String? { partial?.tourGuideIntro }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let photos = partial?.photos, !photos.isEmpty {
                    photoCarousel(photos)
                } else if isStreaming {
                    photoPlaceholder
                }

                if let summary = partial?.summary {
                    Text(summary).font(.headline)
                } else if isStreaming {
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBar(); SkeletonBar(width: 220)
                    }
                }

                actionsRow

                if partial?.tier == "premium" {
                    Label("Premium narration", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.purple)
                }

                if showDirChooser, let place = vm.selectedPlace {
                    directionsChooser(place)
                }

                if let info = vm.routeInfo {
                    Label(info, systemImage: vm.transportMode.symbol)
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                }

                if let intro {
                    section("About") { Text(intro) }
                } else if isStreaming {
                    section("About") {
                        VStack(alignment: .leading, spacing: 6) {
                            SkeletonBar(); SkeletonBar(); SkeletonBar(width: 180)
                        }
                    }
                }

                if let facts = partial?.funFacts, !facts.isEmpty {
                    section("Fun facts") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(facts, id: \.self) { fact in
                                Label(fact, systemImage: "sparkles").labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }

                if let stories = partial?.stories, !stories.isEmpty {
                    section("Stories") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(stories, id: \.self) { story in
                                VStack(alignment: .leading, spacing: 4) {
                                    if let title = story.first { Text(title).font(.subheadline.bold()) }
                                    if let body = story.second { Text(body) }
                                }
                            }
                        }
                    }
                }

                if let history = partial?.history {
                    section("History") { Text(history) }
                }

                if let details = partial?.details, !details.isEmpty {
                    section("Details") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(details, id: \.self) { detail in
                                VStack(alignment: .leading, spacing: 4) {
                                    if let heading = detail.first { Text(heading).font(.subheadline.bold()) }
                                    if let body = detail.second { Text(body) }
                                }
                            }
                        }
                    }
                }

                if let significance = partial?.significance {
                    section("Why it matters") { Text(significance) }
                }

                if let tips = partial?.visitingTips, !tips.isEmpty {
                    section("Visiting tips") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(tips, id: \.self) { tip in
                                Label(tip, systemImage: "lightbulb").labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Save to list", isPresented: $showSaveDialog, titleVisibility: .visible) {
            if let place = vm.selectedPlace {
                ForEach(store.listsByRecent) { list in
                    Button(list.name) { store.add(place, toListID: list.id) }
                }
            }
            Button("New List…") { showNewListAlert = true }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New List Name", isPresented: $showNewListAlert) {
            TextField(vm.currentCity ?? "List name", text: $newListName)
            Button("Create") {
                if let place = vm.selectedPlace {
                    let name = newListName.isEmpty ? (vm.currentCity ?? "") : newListName
                    let list = store.createList(name: name)
                    store.add(place, toListID: list.id)
                }
                newListName = ""
            }
            Button("Cancel", role: .cancel) { newListName = "" }
        }
    }

    private var actionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    speech.playGuide(audioURL: partial?.audioURL, fallbackText: intro ?? "")
                } label: {
                    if speech.isPreparing {
                        HStack(spacing: 6) { ProgressView(); Text("Loading") }
                    } else {
                        Label(speech.isSpeaking ? "Stop" : "Listen",
                              systemImage: speech.isSpeaking ? "stop.fill" : "play.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(intro == nil && partial?.audioURL == nil)

                if let place = vm.selectedPlace {
                    Button {
                        showDirChooser.toggle()
                        if showDirChooser {
                            Task { await vm.computeRouteOptions(to: place) }
                        }
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(showDirChooser ? .accentColor : nil)

                    Button {
                        showSaveDialog = true
                    } label: {
                        Label(store.contains(placeID: place.id) ? "Saved" : "Save",
                              systemImage: store.contains(placeID: place.id) ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .font(.subheadline.bold())
        }
    }

    private func directionsChooser(_ place: Place) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(TransportMode.allCases.enumerated()), id: \.element) { index, mode in
                Button {
                    vm.applyMode(mode)
                    detent = .peek
                    showDirChooser = false
                } label: {
                    HStack {
                        Label(mode.label, systemImage: mode.symbol)
                        Spacer()
                        if vm.computingModes.contains(mode) {
                            ProgressView()
                        } else if let option = vm.routeOptions[mode] {
                            Text(option.eta).foregroundStyle(.secondary)
                        } else {
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                }
                .buttonStyle(.plain)
                .disabled(vm.computingModes.contains(mode) || vm.routeOptions[mode] == nil)
                Divider()
            }
            Button {
                vm.openInMaps(place, mode: vm.transportMode)
                showDirChooser = false
            } label: {
                HStack {
                    Label("Open in Maps instead", systemImage: "arrow.up.forward.app")
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var photoPlaceholder: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(UIColor.systemGray5))
            .frame(height: 170)
            .overlay(ProgressView())
            .shimmering()
    }

    @ViewBuilder
    private func photoCarousel(_ photos: [PlaceContent.Photo]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(photos) { photo in
                    VStack(alignment: .leading, spacing: 4) {
                        AsyncImage(url: URL(string: photo.url)) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                Color(.secondarySystemBackground)
                                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
                            default:
                                Color(.secondarySystemBackground).overlay(ProgressView())
                            }
                        }
                        .frame(width: 260, height: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        if let attribution = photo.attribution, !attribution.isEmpty {
                            Text("📷 \(attribution)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: 260, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ body: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.bold())
            body()
        }
    }
}
