import Combine
import Foundation

struct LocalShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    let text: String
    let date: Date
}

/// Local history contains only text that the user explicitly imports or writes.
/// No pasteboard polling runs in the foreground or background.
@MainActor
final class CompanionShelf: ObservableObject {
    @Published private(set) var items: [LocalShelfItem] = []
    @Published private(set) var storageError: String?

    private let folder: URL
    private let index: URL
    private let maximumItems = 100
    private let maximumBytes = 2_000_000

    init(folder storageFolder: URL? = nil) {
        folder = storageFolder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShowBarCompanion/Shelf", isDirectory: true)
        index = folder.appendingPathComponent("items.json")
        load()
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard text.utf8.count <= 200_000 else {
            storageError = "This text is too large for the shelf. Choose text smaller than 200 KB."
            return false
        }
        var updated = items.filter { $0.text != text }
        updated.insert(LocalShelfItem(id: UUID(), text: text, date: Date()), at: 0)
        updated = Array(updated.prefix(maximumItems))
        while updated.count > 1, (try? JSONEncoder().encode(updated).count) ?? maximumBytes > maximumBytes {
            updated.removeLast()
        }
        guard save(updated) else { return false }
        items = updated
        return true
    }

    func remove(_ item: LocalShelfItem) {
        let updated = items.filter { $0.id != item.id }
        if save(updated) { items = updated }
    }

    /// The caller presents confirmation before clearing user-created history.
    func clear() {
        if save([]) { items = [] }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: index.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
                storageError = "Saved shelf data is too large to load."
                return
            }
            let data = try Data(contentsOf: index)
            let decoded = try JSONDecoder().decode([LocalShelfItem].self, from: data)
            items = Array(decoded.filter { !$0.text.isEmpty && $0.text.utf8.count <= 200_000 }.prefix(maximumItems))
        } catch {
            storageError = "Saved shelf items could not be loaded. Try again after unlocking your device."
        }
    }

    private func save(_ updated: [LocalShelfItem]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            let data = try JSONEncoder().encode(updated)
            guard data.count <= maximumBytes else {
                storageError = "The shelf is full. Remove an item before adding more."
                return false
            }
            try data.write(to: index, options: [.atomic, .completeFileProtection])
            storageError = nil
            return true
        } catch {
            storageError = "Shelf changes could not be saved. Check available storage and unlock your device."
            return false
        }
    }
}
