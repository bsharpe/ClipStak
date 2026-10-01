import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers

public struct ClipImage: Equatable, Sendable, Codable {
    public static let maxInputBytes = 64 * 1024 * 1024
    public static let maxPNGBytes = 10 * 1024 * 1024
    public static let maxPixelCount = 40_000_000

    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let identifier: String

    public init?(data: Data) {
        guard !data.isEmpty, data.count <= Self.maxInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= Self.maxPixelCount / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= Self.maxPNGBytes else { return nil }
        self.init(pngData: output as Data, pixelWidth: image.width, pixelHeight: image.height)
    }

    public var title: String { "Image · \(pixelWidth) × \(pixelHeight)" }
    public var filename: String { "\(identifier).png" }

    // Preserve the exact saved bytes: encoder changes must not invalidate a history entry's hash.
    static func fromStoredPNG(_ data: Data) -> ClipImage? {
        guard !data.isEmpty, data.count <= maxPNGBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maxPixelCount / height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return ClipImage(pngData: data, pixelWidth: width, pixelHeight: height)
    }

    private init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        identifier = SHA256.hash(data: pngData).map { String(format: "%02x", $0) }.joined()
    }

    public func thumbnail(maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, let source = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.identifier == rhs.identifier }

    public init(from decoder: Decoder) throws {
        let data = try decoder.singleValueContainer().decode(Data.self)
        guard let image = Self.fromStoredPNG(data) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid clipboard image"))
        }
        self = image
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(pngData)
    }
}

public enum ClipContent: Codable, Equatable, Sendable {
    case text(String)
    case image(ClipImage)
}
