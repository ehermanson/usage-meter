import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Prepare the existing Mac artwork as an opaque, full-bleed iOS app icon.
// iOS applies its own corner mask; the Mac source includes a transparent margin.
let sourceURL = URL(fileURLWithPath: "Sources/UsageMeter/Resources/usage-meter-app-icon.png")
let destinationURL = URL(
    fileURLWithPath: "iOS/UsageMeter/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
    let context = CGContext(
        data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
        bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            CGColor(red: 0.065, green: 0.078, blue: 0.09, alpha: 1),
            CGColor(red: 0.125, green: 0.19, blue: 0.20, alpha: 1),
        ] as CFArray, locations: [0, 1])
else { fatalError("Cannot load icon artwork") }
context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 1024), options: [])
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: -72, y: -72, width: 1168, height: 1168))
guard let output = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot create icon") }
CGImageDestinationAddImage(destination, output, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot write icon") }
