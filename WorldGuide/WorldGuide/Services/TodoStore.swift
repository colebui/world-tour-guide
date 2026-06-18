import Foundation
import Combine
import CoreLocation
import SwiftUI   // for Array.move(fromOffsets:toOffset:)

/// On-device store for the to-do list. Persists to UserDefaults as JSON and groups saved
/// places by city (resolved via reverse geocoding). Cloud sync arrives in Phase 5.
@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var items: [TodoItem] = [] {
        didSet { persist() }
    }

    private let key = "todo.items.v1"
    private let geocoder = CLGeocoder()

    init() { load() }

    // MARK: - Queries

    func contains(placeID: String) -> Bool {
        items.contains { $0.id == placeID }
    }

    /// Distinct cities with their saved-item counts, sorted by name.
    var cities: [(city: String, count: Int)] {
        Dictionary(grouping: items, by: { $0.city })
            .map { (city: $0.key, count: $0.value.count) }
            .sorted { $0.city < $1.city }
    }

    func items(in city: String) -> [TodoItem] {
        items.filter { $0.city == city }.sorted { $0.order < $1.order }
    }

    // MARK: - Mutations

    func add(_ place: Place) {
        guard !contains(placeID: place.id) else { return }
        let order = (items.map(\.order).max() ?? -1) + 1
        let item = TodoItem(
            id: place.id, name: place.name,
            lat: place.coordinate.latitude, lng: place.coordinate.longitude,
            types: place.types, city: "Saved", isDone: false, order: order
        )
        items.append(item)
        Task { await resolveCity(for: place.id, coordinate: place.coordinate) }
    }

    func remove(placeID: String) {
        items.removeAll { $0.id == placeID }
    }

    func toggleDone(_ item: TodoItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].isDone.toggle()
    }

    func move(city: String, from source: IndexSet, to destination: Int) {
        var ordered = items(in: city)
        ordered.move(fromOffsets: source, toOffset: destination)
        for (i, it) in ordered.enumerated() {
            if let idx = items.firstIndex(where: { $0.id == it.id }) {
                items[idx].order = i
            }
        }
    }

    func delete(city: String, at offsets: IndexSet) {
        let ordered = items(in: city)
        let ids = offsets.map { ordered[$0].id }
        items.removeAll { ids.contains($0.id) }
    }

    // MARK: - City resolution (free, Apple reverse geocoding)

    private func resolveCity(for id: String, coordinate: CLLocationCoordinate2D) async {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await geocoder.reverseGeocodeLocation(location).first else { return }
        let city = placemark.locality
            ?? placemark.subAdministrativeArea
            ?? placemark.administrativeArea
            ?? "Saved"
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].city = city
        }
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) else { return }
        items = decoded
    }
}
