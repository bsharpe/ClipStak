import Foundation

public final class HistoryPersistence {
    public let url: URL
    public private(set) var backupURL: URL?
    public private(set) var lastError: Error?
    public private(set) var canSave = true

    public init(url: URL) {
        self.url = url
    }

    public func load() -> ClipStore {
        guard FileManager.default.fileExists(atPath: url.path) else { return ClipStore() }
        do {
            return try ClipStore.load(from: url)
        } catch is DecodingError {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).unreadable-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: url, to: backup)
                backupURL = backup
            } catch {
                canSave = false
                lastError = error
            }
            return ClipStore()
        } catch {
            canSave = false
            lastError = error
            return ClipStore()
        }
    }

    @discardableResult
    public func save(_ store: ClipStore) -> Bool {
        guard canSave else { return false }
        do {
            try store.save(to: url)
            lastError = nil
            return true
        } catch {
            lastError = error
            return false
        }
    }
}
