import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import ClipStakCore

final class ImageClipTests: XCTestCase {
    func testImageClipsHavePixelDimensionsAndAMenuTitle() throws {
        let image = try XCTUnwrap(ClipImage(data: imageData(width: 3, height: 2)))
        var store = ClipStore()
        XCTAssertEqual(store.record(content: .image(image), appName: "Preview", bundlePath: nil, at: date), .recorded)
        XCTAssertEqual(store.current?.image?.pixelWidth, 3)
        XCTAssertEqual(store.current?.image?.pixelHeight, 2)
        XCTAssertEqual(store.menuItems().first?.title, "Image · 3 × 2")
        XCTAssertEqual(store.bezelText(), "Image · 3 × 2")
        let thumbnail = try XCTUnwrap(image.thumbnail(maxPixelSize: 2))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 2)
    }

    func testImagesShareHistoryWithTextAndDuplicatesMoveToTheFront() throws {
        let image = try XCTUnwrap(ClipImage(data: imageData()))
        var store = ClipStore()
        XCTAssertEqual(store.record(content: .image(image), appName: "Preview", bundlePath: nil, at: date), .recorded)
        XCTAssertEqual(store.record(content: .image(image), appName: "Preview", bundlePath: nil, at: date), .ignored)
        XCTAssertEqual(store.record(text: "text", appName: "Code", bundlePath: nil, at: date), .recorded)
        XCTAssertEqual(store.record(content: .image(image), appName: "Safari", bundlePath: nil, at: date), .recorded)
        XCTAssertEqual(store.clips.count, 2)
        XCTAssertEqual(store.current?.image, image)
        XCTAssertEqual(store.current?.appName, "Safari")
        XCTAssertEqual(store.clips[1].text, "text")
        store.paused = true
        XCTAssertEqual(store.record(content: .image(image), appName: "", bundlePath: nil, at: date), .ignored)
    }

    func testInvalidAndOversizedImageDataAreRejected() {
        XCTAssertNil(ClipImage(data: Data("not an image".utf8)))
        XCTAssertNil(ClipImage(data: Data(count: ClipImage.maxInputBytes + 1)))
    }

    func testImageByteBudgetKeepsNewestClipsAndAValidSelection() throws {
        let older = try XCTUnwrap(ClipImage(data: imageData(width: 2, height: 2)))
        let newer = try XCTUnwrap(ClipImage(data: imageData(width: 3, height: 2)))
        var store = ClipStore()
        _ = store.record(content: .image(older), appName: "", bundlePath: nil, at: date)
        _ = store.record(text: "between images", appName: "", bundlePath: nil, at: date)
        _ = store.record(content: .image(newer), appName: "", bundlePath: nil, at: date)
        store.oldest()
        store.trimToLimits(imageByteLimit: newer.pngData.count)
        XCTAssertEqual(store.clips.count, 2)
        XCTAssertEqual(store.clips.first?.image, newer)
        XCTAssertEqual(store.current?.text, "between images")
        XCTAssertEqual(store.index, 1)
    }

    func testImagesPersistAsPrivateFilesAndMixedHistorySurvivesRestart() throws {
        try withHistory { url in
            let image = try XCTUnwrap(ClipImage(data: imageData()))
            var store = ClipStore()
            _ = store.record(text: "keep this text", appName: "Code", bundlePath: nil, at: date)
            _ = store.record(content: .image(image), appName: "Preview", bundlePath: nil, at: date)
            store.sticky = true
            store.paused = true
            try store.save(to: url)
            let imageURL = url.deletingLastPathComponent().appendingPathComponent("images/\(image.filename)")
            XCTAssertEqual(try Data(contentsOf: imageURL), image.pngData)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: imageURL.path)[.posixPermissions] as? Int, 0o600)
            let json = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(json.contains(image.pngData.base64EncodedString()))
            XCTAssertEqual(try ClipStore.load(from: url), store)
        }
    }

    func testLegacyTextHistoryStillLoads() throws {
        try withHistory { url in
            let json = """
            {"clips":[{"text":"old text","appName":"Code","copiedAt":"2023-11-14T22:13:20Z"}],"sticky":true,"paused":false}
            """
            try Data(json.utf8).write(to: url)
            let store = try ClipStore.load(from: url)
            XCTAssertEqual(store.current?.text, "old text")
            XCTAssertNil(store.current?.image)
            XCTAssertTrue(store.sticky)
        }
    }

    func testPersistedPNGsAreLoadedWithoutReencoding() throws {
        try withHistory { url in
            var png = try imageData()
            let payload = Array("Comment\u{0}keep this metadata".utf8)
            let chunkBody = Array("tEXt".utf8) + payload
            var crc: UInt32 = 0xffffffff
            for byte in chunkBody {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
            }
            func bytes(_ value: UInt32) -> [UInt8] {
                [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
            }
            png.insert(contentsOf: bytes(UInt32(payload.count)) + chunkBody + bytes(crc ^ 0xffffffff), at: png.count - 12)
            let identifier = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            let images = url.deletingLastPathComponent().appendingPathComponent("images")
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try png.write(to: images.appendingPathComponent("\(identifier).png"))
            let snapshot: [String: Any] = [
                "clips": [["image": ["identifier": identifier, "pixelWidth": 2, "pixelHeight": 2],
                           "appName": "", "copiedAt": "2023-11-14T22:13:20Z"]],
                "sticky": false, "paused": false,
            ]
            try JSONSerialization.data(withJSONObject: snapshot).write(to: url)
            XCTAssertEqual(try ClipStore.load(from: url).current?.image?.pngData, png)
        }
    }

    func testDeletingClearingAndEvictingImagesRemovesTheirFiles() throws {
        try withHistory { url in
            let image = try XCTUnwrap(ClipImage(data: imageData()))
            let imageURL = url.deletingLastPathComponent().appendingPathComponent("images/\(image.filename)")
            var store = ClipStore()
            _ = store.record(content: .image(image), appName: "", bundlePath: nil, at: date)
            try store.save(to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
            XCTAssertTrue(store.deleteCurrent())
            try store.save(to: url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))

            _ = store.record(content: .image(image), appName: "", bundlePath: nil, at: date)
            try store.save(to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
            store.clear()
            try store.save(to: url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))

            _ = store.record(content: .image(image), appName: "", bundlePath: nil, at: date)
            try store.save(to: url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))
            for n in 0..<ClipStore.capacity {
                _ = store.record(text: "clip \(n)", appName: "", bundlePath: nil, at: date)
            }
            try store.save(to: url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
            XCTAssertEqual(try ClipStore.load(from: url).clips.count, ClipStore.capacity)
        }
    }

    func testMissingOrCorruptImageFilesDoNotDiscardTextHistory() throws {
        try withHistory { url in
            let image = try XCTUnwrap(ClipImage(data: imageData()))
            var store = ClipStore()
            _ = store.record(text: "survives", appName: "", bundlePath: nil, at: date)
            _ = store.record(content: .image(image), appName: "", bundlePath: nil, at: date)
            try store.save(to: url)
            let imageURL = url.deletingLastPathComponent().appendingPathComponent("images/\(image.filename)")
            try FileManager.default.removeItem(at: imageURL)
            XCTAssertEqual(try ClipStore.load(from: url).clips.map(\.text), ["survives"])
            try Data("broken".utf8).write(to: imageURL)
            XCTAssertEqual(try ClipStore.load(from: url).clips.map(\.text), ["survives"])
        }
    }

    func testRecoveringMalformedHistoryPreservesImageFilesForRecovery() throws {
        try withHistory { url in
            let image = try XCTUnwrap(ClipImage(data: imageData()))
            var store = ClipStore()
            _ = store.record(content: .image(image), appName: "", bundlePath: nil, at: date)
            try store.save(to: url)
            try Data("broken history".utf8).write(to: url)
            let persistence = HistoryPersistence(url: url)
            XCTAssertTrue(persistence.load().clips.isEmpty)
            XCTAssertNotNil(persistence.backupURL)
            XCTAssertTrue(persistence.save(ClipStore()))
            let imageURL = url.deletingLastPathComponent().appendingPathComponent("images/\(image.filename)")
            XCTAssertEqual(try Data(contentsOf: imageURL), image.pngData)
        }
    }

    private func withHistory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipstak-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.appendingPathComponent("history.json"))
    }

    private var date: Date { Date(timeIntervalSince1970: 1_700_000_000) }

    private func imageData(width: Int = 2, height: Int = 2) throws -> Data {
        let pixels = Data(repeating: 255, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
