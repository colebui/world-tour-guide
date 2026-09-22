import SwiftUI

/// The "Saved" tab: a reorderable list of named lists. Tapping one pushes its detail
/// (handled by the parent sheet's NavigationStack via `navigationDestination(for: UUID)`).
struct TodoView: View {
    @ObservedObject var store: TodoStore
    var defaultCity: String? = nil

    @State private var showNewListAlert = false
    @State private var newListName = ""

    var body: some View {
        Group {
            if store.lists.isEmpty {
                ContentUnavailableView {
                    Label("No lists yet", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Create a list, then save places to it from any guide.")
                } actions: {
                    Button("Create List") { showNewListAlert = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(store.lists) { list in
                        NavigationLink(value: list.id) {
                            HStack(spacing: 12) {
                                Image(systemName: "list.bullet.rectangle.fill").foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.name)
                                    Text("\(list.items.count) place\(list.items.count == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onMove { store.moveLists(from: $0, to: $1) }
                    .onDelete { store.deleteLists(at: $0) }
                }
                .listStyle(.plain)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showNewListAlert = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("New list")
            }
        }
        .alert("New List", isPresented: $showNewListAlert) {
            TextField(defaultCity ?? "List name", text: $newListName)
            Button("Create") {
                store.createList(name: newListName.isEmpty ? (defaultCity ?? "") : newListName)
                newListName = ""
            }
            Button("Cancel", role: .cancel) { newListName = "" }
        }
    }
}

/// Detail of a single list: places with checkboxes, drag-to-reorder, swipe-to-delete.
struct TodoListDetailView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var vm: MapViewModel
    let listID: UUID
    let onOpen: (Place) -> Void

    private func listContains(_ placeID: String) -> Bool {
        store.list(listID)?.items.contains { $0.id == placeID } ?? false
    }

    var body: some View {
        List {
            if let place = vm.selectedPlace, !listContains(place.id) {
                Button {
                    store.add(place, toListID: listID)
                } label: {
                    Label("Add \(place.name)", systemImage: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
            }
            if let list = store.list(listID) {
                ForEach(list.items) { item in
                    HStack(spacing: 12) {
                        Button {
                            store.toggleDone(placeID: item.id, inListID: listID)
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
                .onMove { store.moveItems(inListID: listID, from: $0, to: $1) }
                .onDelete { store.deleteItems(inListID: listID, at: $0) }
            }
        }
        .navigationTitle(store.list(listID)?.name ?? "List")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
    }
}
