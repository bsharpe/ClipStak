import AppKit
import ClipStakCore
import ImageIO
import UniformTypeIdentifiers

public enum ClipPasteboard {
    public static func read(from pasteboard: NSPasteboard) -> ClipContent? {
        guard ClipboardPolicy.shouldCapture(types: pasteboard.types?.map(\.rawValue) ?? []) else { return nil }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = ClipImage(data: data) {
                return .image(image)
            }
        }
        return pasteboard.string(forType: .string).map(ClipContent.text)
    }

    public static func contains(_ content: ClipContent, on pasteboard: NSPasteboard) -> Bool {
        switch content {
        case .text(let text):
            return pasteboard.string(forType: .string) == text
        case .image(let image):
            return pasteboard.data(forType: .png) == image.pngData
        }
    }

    public static func write(_ content: ClipContent, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        switch content {
        case .text(let text):
            guard item.setString(text, forType: .string) else { return false }
        case .image(let image):
            guard item.setData(image.pngData, forType: .png) else { return false }
            if let tiff = tiffData(image) {
                item.setData(tiff, forType: .tiff)
            }
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    private static func tiffData(_ image: ClipImage) -> Data? {
        guard let source = CGImageSourceCreateWithData(image.pngData as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, decoded, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= ClipImage.maxInputBytes else { return nil }
        return data as Data
    }
}
