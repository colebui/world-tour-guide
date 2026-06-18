import SwiftUI

/// Renders whatever sections the content contains, in a fixed order. Missing
/// sections simply don't appear. (Photos arrive in Phase 2.)
struct PlaceDetailView: View {
    let content: PlaceContent
    @ObservedObject var vm: MapViewModel
    @ObservedObject var speech: SpeechService
    @ObservedObject var store: TodoStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let photos = content.photos, !photos.isEmpty {
                    photoCarousel(photos)
                }

                Text(content.summary)
                    .font(.headline)

                actionsRow

                if let summary = vm.routeSummary {
                    Label(summary, systemImage: "figure.walk")
                        .font(.subheadline)
                        .foregroundStyle(.blue)
                }

                section("About") {
                    Text(content.tourGuideIntro)
                }

                if let facts = content.funFacts, !facts.isEmpty {
                    section("Fun facts") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(facts, id: \.self) { fact in
                                Label(fact, systemImage: "sparkles")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }

                if let stories = content.stories, !stories.isEmpty {
                    section("Stories") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(stories, id: \.self) { story in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(story.title).font(.subheadline.bold())
                                    Text(story.body)
                                }
                            }
                        }
                    }
                }

                if let history = content.history {
                    section("History") { Text(history) }
                }

                if let details = content.details, !details.isEmpty {
                    section("Details") {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(details, id: \.self) { detail in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(detail.heading).font(.subheadline.bold())
                                    Text(detail.body)
                                }
                            }
                        }
                    }
                }

                if let significance = content.significance {
                    section("Why it matters") { Text(significance) }
                }

                if let tips = content.visitingTips, !tips.isEmpty {
                    section("Visiting tips") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(tips, id: \.self) { tip in
                                Label(tip, systemImage: "lightbulb")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    speech.toggle(content.tourGuideIntro)
                } label: {
                    Label(speech.isSpeaking ? "Stop" : "Listen",
                          systemImage: speech.isSpeaking ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)

                if let place = vm.selectedPlace {
                    Button {
                        Task { await vm.computeRoute(to: place) }
                    } label: {
                        Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        vm.openInMaps(place)
                    } label: {
                        Label("Navigate", systemImage: "location.north.line.fill")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        if store.contains(placeID: place.id) {
                            store.remove(placeID: place.id)
                        } else {
                            store.add(place)
                        }
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
