import Foundation

/// A user-named to-do list. `lastModified` drives the "default to last updated" save prompt;
/// the store's array order is the (reorderable) display order.
struct TodoList: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var lastModified: Date
    var items: [TodoItem]

    init(name: String) {
        id = UUID()
        self.name = name
        lastModified = Date()
        items = []
    }
}
