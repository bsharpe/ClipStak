import XCTest
import AppKit
import ClipStakCore
import ClipStakClipboard

final class ClipPasteboardTests: XCTestCase {
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    func testPNGCapturePrefersTheImageOverItsTextRepresentation() throws {
        pasteboard.setData(try bitmap().representation(using: .png, properties: [:]), forType: .png)
        pasteboard.setString("image label", forType: .string)
        guard case .image(let image) = ClipPasteboard.read(from: pasteboard) else {
            return XCTFail("Expected an image clip")
        }
        XCTAssertEqual(image.pixelWidth, 2)
        XCTAssertEqual(image.pixelHeight, 3)
        let loaded = try XCTUnwrap(NSBitmapImageRep(data: image.pngData))
        XCTAssertEqual(try XCTUnwrap(loaded.colorAt(x: 1, y: 0)).alphaComponent, 0, accuracy: 0.01)
    }

    func testTIFFCaptureIsNormalizedToPNG() throws {
        pasteboard.setData(try bitmap().representation(using: .tiff, properties: [:]), forType: .tiff)
        guard case .image(let image) = ClipPasteboard.read(from: pasteboard) else {
            return XCTFail("Expected an image clip")
        }
        XCTAssertEqual(image.pixelWidth, 2)
        XCTAssertEqual(image.pixelHeight, 3)
        XCTAssertEqual(Array(image.pngData.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
    }

    func testImagePasteProvidesPNGAndTIFFAndClearsOldText() throws {
        let data = try XCTUnwrap(bitmap().representation(using: .png, properties: [:]))
        let image = try XCTUnwrap(ClipImage(data: data))
        pasteboard.setString("stale text", forType: .string)
        XCTAssertTrue(ClipPasteboard.write(.image(image), to: pasteboard))
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
        XCTAssertEqual(ClipPasteboard.read(from: pasteboard), .image(image))
    }

    func testPrivacyMarkersPreventImageCapture() throws {
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            pasteboard.clearContents()
            pasteboard.setData(try bitmap().representation(using: .png, properties: [:]), forType: .png)
            pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(marker))
            XCTAssertNil(ClipPasteboard.read(from: pasteboard))
        }
    }

    func testTextCaptureAndPasteStillWork() {
        XCTAssertTrue(ClipPasteboard.write(.text("hello"), to: pasteboard))
        XCTAssertEqual(ClipPasteboard.read(from: pasteboard), .text("hello"))
        XCTAssertNil(pasteboard.data(forType: .png))
        pasteboard.clearContents()
        XCTAssertNil(ClipPasteboard.read(from: pasteboard))
    }

    private func bitmap() throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 3,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32
        ))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for offset in 0..<24 { pixels[offset] = 0 }
        pixels[0] = 255
        pixels[3] = 255
        return bitmap
    }
}
