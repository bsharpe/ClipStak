import Foundation

public struct Clip: Codable, Equatable, Sendable {
    public var text: String
    public var appName: String
    public var bundlePath: String?
    public var copiedAt: Date

    public init(text: String, appName: String, bundlePath: String?, copiedAt: Date) {
        self.text = text
        self.appName = appName
        self.bundlePath = bundlePath
        self.copiedAt = copiedAt
    }
}

public struct ClipStore: Equatable {
    public static let capacity = 40
    public static let menuCount = 10
    public static let menuPreviewLength = 40
    public static let bezelPreviewLength = 2000
    public static let maxClipLength = 1_000_000

    public private(set) var clips: [Clip]
    /// 0 is the newest clip. Esc leaves this where it was so the next gesture resumes.
    public private(set) var index: Int
    /// When false, releasing the modifier keys pastes. That is the Flycut default.
    public var sticky: Bool
    public var paused: Bool

    public init(clips: [Clip] = [], index: Int = 0, sticky: Bool = false, paused: Bool = false) {
        self.clips = clips
        self.index = clips.isEmpty ? 0 : min(max(0, index), clips.count - 1)
        self.sticky = sticky
        self.paused = paused
    }

    public enum RecordResult: Equatable {
        case ignored
        case recorded
    }

    /// Newest lands at index 0. An empty clip, or one large enough to stall the UI, is ignored.
    /// The same text as the current newest clip does not grow history. An older duplicate moves to the front.
    public mutating func record(text: String, appName: String, bundlePath: String?, at date: Date) -> RecordResult {
        if paused || text.isEmpty || text.count > Self.maxClipLength {
            return .ignored
        }
        if clips.first?.text == text {
            return .ignored
        }
        let clip = Clip(text: text, appName: appName, bundlePath: bundlePath, copiedAt: date)
        if let existing = clips.firstIndex(where: { $0.text == text }) {
            clips.remove(at: existing)
        }
        clips.insert(clip, at: 0)
        if clips.count > Self.capacity {
            clips.removeLast(clips.count - Self.capacity)
        }
        index = 0
        return .recorded
    }

    public var current: Clip? {
        guard clips.indices.contains(index) else { return nil }
        return clips[index]
    }

    @discardableResult
    public mutating func older() -> Bool {
        guard index + 1 < clips.count else { return false }
        index += 1
        return true
    }

    @discardableResult
    public mutating func newer() -> Bool {
        guard index > 0 else { return false }
        index -= 1
        return true
    }

    public mutating func newest() {
        index = 0
    }

    public mutating func select(_ newIndex: Int) {
        guard !clips.isEmpty else { return }
        index = min(max(0, newIndex), clips.count - 1)
    }

    public mutating func oldest() {
        index = max(clips.count - 1, 0)
    }

    public mutating func pageOlder() {
        guard !clips.isEmpty else { return }
        index = min(index + 10, clips.count - 1)
    }

    public mutating func pageNewer() {
        index = max(index - 10, 0)
    }

    /// Keyboard digits: 1 is the newest, 0 is the 10th.
    public mutating func jumpToNumberKey(_ digit: Int) {
        guard !clips.isEmpty else { return }
        let target = digit == 0 ? 9 : digit - 1
        index = min(max(0, target), clips.count - 1)
    }

    @discardableResult
    public mutating func deleteCurrent() -> Bool {
        guard clips.indices.contains(index) else { return false }
        clips.remove(at: index)
        if clips.isEmpty {
            index = 0
        } else if index >= clips.count {
            index = clips.count - 1
        }
        return true
    }

    public mutating func moveCurrentToFront() {
        guard let clip = current, index != 0 else { return }
        clips.remove(at: index)
        clips.insert(clip, at: 0)
        index = 0
    }

    public mutating func clear() {
        clips.removeAll()
        index = 0
    }

    public func menuItems() -> [(index: Int, title: String)] {
        clips.prefix(Self.menuCount).enumerated().map { offset, clip in
            (offset, Self.menuTitle(clip.text))
        }
    }

    public func bezelText() -> String {
        guard let text = current?.text else { return "" }
        if text.count <= Self.bezelPreviewLength { return text }
        return String(text.prefix(Self.bezelPreviewLength))
    }

    public var positionLabel: String {
        guard !clips.isEmpty else { return "" }
        return "\(index + 1) of \(clips.count)"
    }

    public static func menuTitle(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if flat.count <= menuPreviewLength { return flat }
        return String(flat.prefix(menuPreviewLength - 1)) + "…"
    }

    public static func importingFlycutStore(_ store: [String: Any]) -> [Clip] {
        guard let list = store["jcList"] as? [[String: Any]] else { return [] }
        var clips: [Clip] = []
        for item in list {
            guard let text = item["Contents"] as? String, !text.isEmpty, text.count <= maxClipLength else { continue }
            let name = item["AppLocalizedName"] as? String ?? ""
            let path = item["AppBundleURL"] as? String
            let stamp = item["Timestamp"] as? Int ?? 0
            clips.append(Clip(
                text: text,
                appName: name,
                bundlePath: path,
                copiedAt: Date(timeIntervalSince1970: TimeInterval(stamp))
            ))
            if clips.count == capacity { break }
        }
        return clips
    }

    public static func load(from url: URL) throws -> ClipStore {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        return ClipStore(clips: snapshot.clips, sticky: snapshot.sticky, paused: snapshot.paused)
    }

    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Snapshot(clips: clips, sticky: sticky, paused: paused))
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private struct Snapshot: Codable, Equatable {
    var clips: [Clip]
    var sticky: Bool
    var paused: Bool
}
