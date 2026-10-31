import XCTest
@testable import ShowBarCompanion

@MainActor
final class CompanionShelfTests: XCTestCase {
    private func withShelf(_ test: (CompanionShelf, URL) throws -> Void) rethrows {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try test(CompanionShelf(folder: folder), folder)
    }

    func testShelfPreservesCodeWhitespaceAndPersistsIt() {
        withShelf { shelf, folder in
            let code = "    let value = 42\n"
            shelf.add(code)
            XCTAssertEqual(shelf.items.first?.text, code)
            XCTAssertNil(shelf.storageError)
            let reloaded = CompanionShelf(folder: folder)
            XCTAssertEqual(reloaded.items, shelf.items)
            XCTAssertNil(reloaded.storageError)
        }
    }

    func testDuplicateMovesToFrontAndWhitespaceIsIgnored() {
        withShelf { shelf, _ in
            shelf.add("first")
            shelf.add("second")
            shelf.add("first")
            shelf.add(" \n\t ")
            XCTAssertEqual(shelf.items.map(\.text), ["first", "second"])
        }
    }

    func testShelfKeepsAtMostOneHundredRecentItems() {
        withShelf { shelf, folder in
            for index in 0..<110 { shelf.add("Item \(index)") }
            XCTAssertEqual(shelf.items.count, 100)
            XCTAssertEqual(shelf.items.first?.text, "Item 109")
            XCTAssertEqual(shelf.items.last?.text, "Item 10")
            XCTAssertEqual(CompanionShelf(folder: folder).items.count, 100)
        }
    }

    func testOversizedItemsAreRejectedWithoutLosingExistingItems() {
        withShelf { shelf, _ in
            shelf.add("keep me")
            shelf.add(String(repeating: "x", count: 200_001))
            XCTAssertEqual(shelf.items.map(\.text), ["keep me"])
            XCTAssertNotNil(shelf.storageError)
        }
    }

    func testStorageBudgetTrimsOlderItemsBeforeWriting() throws {
        try withShelf { shelf, folder in
            for index in 0..<20 { shelf.add("\(index)" + String(repeating: "a", count: 150_000)) }
            let data = try Data(contentsOf: folder.appendingPathComponent("items.json"))
            XCTAssertLessThanOrEqual(data.count, 2_000_000)
            XCTAssertLessThan(shelf.items.count, 20)
            XCTAssertEqual(shelf.items.first?.text.prefix(2), "19")
            XCTAssertEqual(CompanionShelf(folder: folder).items, shelf.items)
        }
    }

    func testRemoveAndClearPersistImmediately() {
        withShelf { shelf, folder in
            shelf.add("first")
            shelf.add("second")
            if let first = shelf.items.first { shelf.remove(first) }
            XCTAssertEqual(CompanionShelf(folder: folder).items.map(\.text), ["first"])
            shelf.clear()
            XCTAssertTrue(CompanionShelf(folder: folder).items.isEmpty)
        }
    }

    func testFailedWritesPreserveVisibleHistory() throws {
        try withShelf { shelf, folder in
            shelf.add("keep this")
            let original = shelf.items
            let index = folder.appendingPathComponent("items.json")
            try FileManager.default.removeItem(at: index)
            try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)

            XCTAssertFalse(shelf.add("cannot save this"))
            XCTAssertEqual(shelf.items, original)
            shelf.clear()
            XCTAssertEqual(shelf.items, original)
            if let first = original.first { shelf.remove(first) }
            XCTAssertEqual(shelf.items, original)
            XCTAssertNotNil(shelf.storageError)
        }
    }

    func testCorruptStorageReportsErrorInsteadOfLoadingPartialHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("invalid json".utf8).write(to: folder.appendingPathComponent("items.json"))
        let shelf = CompanionShelf(folder: folder)
        XCTAssertTrue(shelf.items.isEmpty)
        XCTAssertNotNil(shelf.storageError)
    }
}
