import Foundation
import Combine
import SwiftUI   // for Array.move(fromOffsets:toOffset:)
import FirebaseAuth
import FirebaseFirestore

/// Cloud-synced store for named to-do lists, kept at `users/{uid}/lists/{listId}` in Firestore.
/// Firestore's on-device cache makes this offline-first (reads/writes work offline and sync later),
/// and a snapshot listener keeps `lists` live across devices. The public API is unchanged from the
/// old UserDefaults version, so the views don't change. Mutations update `lists` optimistically and
/// write through to Firestore; the listener reconciles.
@MainActor
final class TodoStore: ObservableObject {
    @Published private(set) var lists: [TodoList] = []

    private let db = Firestore.firestore()
    private var listener: ListenerRegistration?
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var uid: String?

    init() {
        // Re-bind whenever the signed-in user changes (anonymous → linked keeps the same uid, so
        // lists stay; a true account switch re-points to that user's lists).
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in self?.rebind(to: user?.uid) }
        }
        rebind(to: Auth.auth().currentUser?.uid)
    }

    deinit {
        listener?.remove()
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
    }

    private func listsRef(_ uid: String) -> CollectionReference {
        db.collection("users").document(uid).collection("lists")
    }

    private func rebind(to newUid: String?) {
        guard newUid != uid else { return }
        listener?.remove(); listener = nil
        uid = newUid
        lists = []
        guard let uid = newUid else { return }
        migrateLocalIfNeeded(to: uid)
        listener = listsRef(uid).order(by: "order").addSnapshotListener { [weak self] snap, error in
            if let error { print("todo listener error: \(error)"); return }
            let decoded = snap?.documents.compactMap { try? $0.data(as: TodoList.self) } ?? []
            Task { @MainActor in self?.lists = decoded }
        }
    }

    // MARK: - Queries (unchanged)

    var listsByRecent: [TodoList] { lists.sorted { $0.lastModified > $1.lastModified } }
    func contains(placeID: String) -> Bool { lists.contains { $0.items.contains { $0.id == placeID } } }
    func list(_ id: UUID) -> TodoList? { lists.first { $0.id == id } }

    // MARK: - List mutations

    @discardableResult
    func createList(name: String) -> TodoList {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let list = TodoList(name: trimmed.isEmpty ? "My List" : trimmed)
        lists.append(list)                       // optimistic, so an immediate add() finds it
        write(list, order: lists.count - 1)
        return list
    }

    func moveLists(from source: IndexSet, to destination: Int) {
        lists.move(fromOffsets: source, toOffset: destination)
        writeOrder()
    }

    func deleteLists(at offsets: IndexSet) {
        let removed = offsets.map { lists[$0] }
        lists.remove(atOffsets: offsets)
        removed.forEach { delete($0.id) }
        writeOrder()
    }

    // MARK: - Item mutations

    func add(_ place: Place, toListID id: UUID) {
        update(id) { list in
            if !list.items.contains(where: { $0.id == place.id }) {
                list.items.append(TodoItem(place: place))
            }
        }
    }

    func removeItem(placeID: String, fromListID id: UUID) {
        update(id) { $0.items.removeAll { $0.id == placeID } }
    }

    func toggleDone(placeID: String, inListID id: UUID) {
        update(id) { list in
            if let j = list.items.firstIndex(where: { $0.id == placeID }) {
                list.items[j].isDone.toggle()
            }
        }
    }

    func moveItems(inListID id: UUID, from source: IndexSet, to destination: Int) {
        update(id) { $0.items.move(fromOffsets: source, toOffset: destination) }
    }

    func deleteItems(inListID id: UUID, at offsets: IndexSet) {
        update(id) { $0.items.remove(atOffsets: offsets) }
    }

    // MARK: - Internals

    private func update(_ id: UUID, _ mutate: (inout TodoList) -> Void) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        mutate(&lists[i])
        lists[i].lastModified = Date()
        write(lists[i], order: i)
    }

    private func write(_ list: TodoList, order: Int) {
        guard let uid else { return }
        do {
            var data = try Firestore.Encoder().encode(list)
            data["order"] = order
            listsRef(uid).document(list.id.uuidString).setData(data)
        } catch { print("todo write error: \(error)") }
    }

    private func delete(_ id: UUID) {
        guard let uid else { return }
        listsRef(uid).document(id.uuidString).delete()
    }

    private func writeOrder() {
        guard let uid else { return }
        for (i, list) in lists.enumerated() {
            listsRef(uid).document(list.id.uuidString).setData(["order": i], merge: true)
        }
    }

    /// One-time import of any pre-cloud UserDefaults lists into this user's Firestore collection.
    private func migrateLocalIfNeeded(to uid: String) {
        let key = "todo.lists.v1", migratedKey = "todo.migrated.v1"
        guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
        UserDefaults.standard.set(true, forKey: migratedKey)
        guard let data = UserDefaults.standard.data(forKey: key),
              let local = try? JSONDecoder().decode([TodoList].self, from: data), !local.isEmpty else { return }
        for (i, list) in local.enumerated() { write(list, order: i) }
        UserDefaults.standard.removeObject(forKey: key)
    }
}
