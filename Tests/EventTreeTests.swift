import Testing

@testable import LightTable

private struct FakeEvent {
    let name: String
}

private func tree(_ names: String...) -> EventTree.Node<FakeEvent> {
    EventTree.build(names.map(FakeEvent.init), name: \.name)[0]
}

@Suite("Folders read out of event names")
struct EventTreeTests {
    @Test("A name with no separator stays at the top")
    func flat() {
        let root = tree("Hawaii", "2010_Maurice")

        #expect(root.children.isEmpty)
        #expect(root.items.map(\.name) == ["Hawaii", "2010_Maurice"])
    }

    @Test("A path becomes folders, and the row keeps only the last part")
    func nested() {
        let root = tree("kotoko / Nude / square nude")
        let kotoko = root.children[0]
        let nude = kotoko.children[0]

        #expect(kotoko.name == "kotoko")
        #expect(nude.name == "Nude")
        #expect(nude.items.map(\.name) == ["kotoko / Nude / square nude"])
        #expect(nude.path == "kotoko / Nude")
    }

    @Test("Events sharing a folder share one node")
    func shared() {
        let root = tree("Places / Hawaii", "Places / Japan / 2011", "Places / Japan / 2012")
        let places = root.children[0]

        #expect(root.children.count == 1)
        #expect(places.items.count == 1)
        #expect(places.children.count == 1)
        #expect(places.children[0].items.count == 2)
    }

    @Test("Folders are sorted, events keep the order they came in")
    func ordering() {
        // The caller sorts events — newest first — and the tree does not
        // second-guess it. Folders are places, and places read better in order.
        let root = tree("Years / 2016 / b", "Places / x", "Years / 2015 / a")

        #expect(root.children.map(\.name) == ["Places", "Years"])
        #expect(root.children[1].children.map(\.name) == ["2015", "2016"])
    }

    @Test("Nothing in, nothing out")
    func empty() {
        #expect(EventTree.build([FakeEvent]() , name: \.name).isEmpty)
    }

    @Test("An empty component does not make an empty folder")
    func emptyComponent() {
        // " / Hawaii" is a name somebody typed, not a folder called nothing.
        let root = tree(" / Hawaii")
        #expect(root.children.isEmpty)
        #expect(root.items.count == 1)
    }
}
