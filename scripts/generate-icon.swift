#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Match StatusIcon.image in ClipStakApp.swift, using its 18-point coordinates.
// Run: swift scripts/generate-icon.swift .build/ClipStak.iconset
guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: generate-icon.swift <output.iconset>")
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func writeIcon(pixels: Int, filename: String) throws {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: pixels * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Could not create icon bitmap") }
    context.scaleBy(x: CGFloat(pixels) / 18, y: CGFloat(pixels) / 18)
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [0.86, 0.16, 0.18, 1])!)
    context.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1, width: 16, height: 16),
                           cornerWidth: 4, cornerHeight: 4, transform: nil))
    context.fillPath()
    context.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.setLineWidth(1.4)
    context.setLineCap(.round)
    for row in 0..<3 {
        let y = 5 + CGFloat(row) * 3.2
        context.move(to: CGPoint(x: 4.5, y: y))
        context.addLine(to: CGPoint(x: 13.5, y: y))
    }
    context.strokePath()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            output.appendingPathComponent(filename) as CFURL,
            UTType.png.identifier as CFString, 1, nil
          ) else { fatalError("Could not create PNG destination") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write icon") }
}

for points in [16, 32, 128, 256, 512] {
    try writeIcon(pixels: points, filename: "icon_\(points)x\(points).png")
    try writeIcon(pixels: points * 2, filename: "icon_\(points)x\(points)@2x.png")
}
