import SwiftUI

/// The "Saved" tab: a list of cities; tapping one shows its saved places with checkboxes
/// and drag-to-reorder. `onOpen` lets the parent switch to the Guide tab and load the place.
struct TodoView: View {
    @ObservedObject var store: TodoStore
    let onOpen: (Place) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView(
                        "No saved places",
                        systemImage: "bookmark",
                        description: Text("Tap the bookmark on a place to add it to your to-do list.")
                    )
                } else {
                    List(store.cities, id: \.city) { entry in
                        NavigationLink(value: entry.city) {
                            HStack {
                                Image(systemName: "building.2").foregroundStyle(.secondary)
                                Text(entry.city)
                                Spacer()
                                Text("\(entry.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationDestination(for: String.self) { city in
                TodoCityView(store: store, city: city, onOpen: onOpen)
            }
        }
    }
}

private struct TodoCityView: View {
    @ObservedObject var store: TodoStore
    let city: String
    let onOpen: (Place) -> Void

    var body: some View {
        List {
            ForEach(store.items(in: city)) { item in
                HStack(spacing: 12) {
                    Button {
                        store.toggleDone(item)
                    } label: {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isDone ? .green : .secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)

                    Text(item.name)
                        .strikethrough(item.isDone)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpen(item.place) }
            }
            .onMove { store.move(city: city, from: $0, to: $1) }
            .onDelete { store.delete(city: city, at: $0) }
        }
        .navigationTitle(city)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}
