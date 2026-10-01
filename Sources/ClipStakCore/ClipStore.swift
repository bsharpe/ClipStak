import Foundation

public struct Clip: Codable, Equatable, Sendable {
    public var content: ClipContent
    /// Text convenience accessor. Use content to distinguish image clips, which return an empty string here.
    public var text: String {
        get {
            if case .text(let text) = content { return text }
            return ""
        }
        set { content = .text(newValue) }
    }
    public var image: ClipImage? {
        if case .image(let image) = content { return image }
        return nil
    }
    public var appName: String
    public var bundlePath: String?
    public var copiedAt: Date

    public init(text: String, appName: String, bundlePath: String?, copiedAt: Date) {
        self.init(content: .text(text), appName: appName, bundlePath: bundlePath, copiedAt: copiedAt)
    }

    public init(content: ClipContent, appName: String, bundlePath: String?, copiedAt: Date) {
        self.content = content
        self.appName = appName
        self.bundlePath = bundlePath
        self.copiedAt = copiedAt
    }

    private enum CodingKeys: String, CodingKey { case content, text, appName, bundlePath, copiedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        content = try values.decodeIfPresent(ClipContent.self, forKey: .content)
            ?? .text(values.decode(String.self, forKey: .text))
        appName = try values.decode(String.self, forKey: .appName)
        bundlePath = try values.decodeIfPresent(String.self, forKey: .bundlePath)
        copiedAt = try values.decode(Date.self, forKey: .copiedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(content, forKey: .content)
        try values.encode(appName, forKey: .appName)
        try values.encodeIfPresent(bundlePath, forKey: .bundlePath)
        try values.encode(copiedAt, forKey: .copiedAt)
    }
}

public struct ClipStore: Equatable {
    public static let capacity = 40
    public static let menuCount = 10
    public static let menuPreviewLength = 40
    public static let bezelPreviewLength = 2000
    public static let maxClipLength = 1_000_000
    public static let maxImageHistoryBytes = 100 * 1024 * 1024

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
        trimToLimits()
    }

    public enum RecordResult: Equatable {
        case ignored
        case recorded
    }

    /// Newest lands at index 0. An empty clip, or one large enough to stall the UI, is ignored.
    /// The same text as the current newest clip does not grow history. An older duplicate moves to the front.
    public mutating func record(text: String, appName: String, bundlePath: String?, at date: Date) -> RecordResult {
        record(content: .text(text), appName: appName, bundlePath: bundlePath, at: date)
    }

    public mutating func record(content: ClipContent, appName: String, bundlePath: String?, at date: Date) -> RecordResult {
        guard !paused else { return .ignored }
        if case .text(let text) = content, text.isEmpty || text.count > Self.maxClipLength { return .ignored }
        if clips.first?.content == content {
            return .ignored
        }
        let clip = Clip(content: content, appName: appName, bundlePath: bundlePath, copiedAt: date)
        if let existing = clips.firstIndex(where: { $0.content == content }) {
            clips.remove(at: existing)
        }
        clips.insert(clip, at: 0)
        trimToLimits()
        index = 0
        return .recorded
    }

    mutating func trimToLimits(imageByteLimit: Int = Self.maxImageHistoryBytes) {
        if clips.count > Self.capacity {
            clips.removeLast(clips.count - Self.capacity)
        }
        var imageBytes = clips.reduce(0) { $0 + ($1.image?.pngData.count ?? 0) }
        while imageBytes > imageByteLimit, let last = clips.popLast() {
            imageBytes -= last.image?.pngData.count ?? 0
        }
        index = clips.isEmpty ? 0 : min(index, clips.count - 1)
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
            (offset, clip.image?.title ?? Self.menuTitle(clip.text))
        }
    }

    public func bezelText() -> String {
        if let image = current?.image { return image.title }
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
        let images = url.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        var clips: [Clip] = []
        var imageBytes = 0
        for stored in snapshot.clips.prefix(Self.capacity) {
            guard let clip = stored.clip(images: images) else { continue }
            imageBytes += clip.image?.pngData.count ?? 0
            if imageBytes > Self.maxImageHistoryBytes { break }
            clips.append(clip)
        }
        return ClipStore(clips: clips, sticky: snapshot.sticky, paused: snapshot.paused)
    }

    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let images = directory.appendingPathComponent("images", isDirectory: true)
        let activeImages = clips.compactMap(\.image)
        if !activeImages.isEmpty {
            try manager.createDirectory(at: images, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for image in activeImages {
                let imageURL = images.appendingPathComponent(image.filename)
                if !manager.fileExists(atPath: imageURL.path) {
                    try Self.writePrivate(image.pngData, to: imageURL)
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Snapshot(clips: clips.map(StoredClip.init), sticky: sticky, paused: paused))
        try Self.writePrivate(data, to: url)

        // A malformed history backup may still reference these files. Keep its assets for recovery.
        let hasBackup = try manager.contentsOfDirectory(atPath: directory.path)
            .contains { $0.hasPrefix("\(url.lastPathComponent).unreadable-") }
        if !hasBackup, manager.fileExists(atPath: images.path) {
            let retained = Set(activeImages.map(\.filename))
            for file in try manager.contentsOfDirectory(at: images, includingPropertiesForKeys: nil) {
                if file.pathExtension == "png", !retained.contains(file.lastPathComponent) {
                    try manager.removeItem(at: file)
                }
            }
        }
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private struct Snapshot: Codable, Equatable {
    var clips: [StoredClip]
    var sticky: Bool
    var paused: Bool
}

private struct StoredClip: Codable, Equatable {
    var text: String?
    var image: StoredImage?
    var appName: String
    var bundlePath: String?
    var copiedAt: Date

    init(_ clip: Clip) {
        if let image = clip.image {
            self.image = StoredImage(identifier: image.identifier, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight)
        } else {
            text = clip.text
        }
        appName = clip.appName
        bundlePath = clip.bundlePath
        copiedAt = clip.copiedAt
    }

    func clip(images: URL) -> Clip? {
        let content: ClipContent
        if let image {
            guard image.identifier.count == 64,
                  image.identifier.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            let url = images.appendingPathComponent("\(image.identifier).png")
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
                  size <= ClipImage.maxPNGBytes,
                  let data = try? Data(contentsOf: url), let loaded = ClipImage.fromStoredPNG(data),
                  loaded.identifier == image.identifier,
                  loaded.pixelWidth == image.pixelWidth, loaded.pixelHeight == image.pixelHeight else { return nil }
            content = .image(loaded)
        } else if let text, !text.isEmpty, text.count <= ClipStore.maxClipLength {
            content = .text(text)
        } else {
            return nil
        }
        return Clip(content: content, appName: appName, bundlePath: bundlePath, copiedAt: copiedAt)
    }
}

private struct StoredImage: Codable, Equatable {
    var identifier: String
    var pixelWidth: Int
    var pixelHeight: Int
}
