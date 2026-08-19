import Foundation

/// Folders for events, read out of their names.
///
/// An event imported from Lightroom is called `kotoko / Nude / square nude`,
/// because that is where it sat in the catalogue — and fifty of those in a flat
/// list is a wall of text with the useful part at the end of every line. The
/// separator is already there, so the tree is derived rather than stored: no
/// migration, nothing to keep in step, and an event named by hand joins a folder
/// simply by being called `Trips / Japan`.
///
/// Generic over the item so the shape can be exercised without SwiftData.
enum EventTree {
    static let separator = " / "

    final class Node<Item> {
        /// The last component — what the row shows.
        let name: String
        /// The whole path, which is what expansion is remembered by.
        let path: String
        var items: [Item] = []
        var children: [Node<Item>] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        var isLeaf: Bool { children.isEmpty }
    }

    /// Builds the tree, keeping the order items arrived in within each folder.
    ///
    /// Folders come before events at every level, each sorted by name, because a
    /// folder is a place and the eye looks for places first. Everything else
    /// keeps the caller's order — which for events is the sort they were given
    /// in, newest first.
    static func build<Item>(_ items: [Item], name: (Item) -> String) -> [Node<Item>] {
        let root = Node<Item>(name: "", path: "")

        for item in items {
            let components = name(item).components(separatedBy: separator)
            let folders = components.dropLast()
            var node = root
            var path = ""
            for folder in folders where !folder.isEmpty {
                path = path.isEmpty ? folder : path + separator + folder
                if let existing = node.children.first(where: { $0.path == path }) {
                    node = existing
                } else {
                    let child = Node<Item>(name: folder, path: path)
                    node.children.append(child)
                    node = child
                }
            }
            node.items.append(item)
        }

        sort(root)
        return root.children.isEmpty && root.items.isEmpty ? [] : [root]
    }

    private static func sort<Item>(_ node: Node<Item>) {
        node.children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for child in node.children { sort(child) }
    }
}
