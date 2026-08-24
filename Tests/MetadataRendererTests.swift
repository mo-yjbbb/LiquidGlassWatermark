import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import UIKit
@testable import LiquidGlassWatermark

final class MetadataRendererTests: XCTestCase {
    func testCompleteMetadataAndStaticRender() throws {
        let url = try makeFixture(includeMetadata: true)
        defer { try? FileManager.default.removeItem(at: url) }

        let metadata = MetadataReader.read(asset: nil, imageURL: url)
        XCTAssertEqual(metadata.device, "Xiaomi 15 Pro")
        XCTAssertEqual(metadata.date, "2026.08.24 16:15:01")
        XCTAssertTrue(metadata.exposure.contains("24mm"))
        XCTAssertTrue(metadata.exposure.contains("F1.78"))
        XCTAssertTrue(metadata.exposure.contains("1/100s"))
        XCTAssertTrue(metadata.exposure.contains("ISO100"))
        XCTAssertEqual(metadata.location, "39°54'26\"N  116°23'29\"E")

        let source = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        XCTAssertNotNil(source)
        let renderer = GlassRenderer(metadata: metadata)
        let first = renderer.render(source!)
        let second = renderer.render(source!)
        XCTAssertEqual(first.extent, source!.extent)
        XCTAssertEqual(second.extent, source!.extent)
        let rendered = renderer.makeCGImage(first)
        XCTAssertNotNil(rendered)
        XCTAssertNotNil(renderer.makeCGImage(second))
        if let rendered {
            let attachment = XCTAttachment(image: UIImage(cgImage: rendered))
            attachment.name = "reference-layout-preview"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testMissingMetadataIsRejectedByValidationInputs() throws {
        let url = try makeFixture(includeMetadata: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = MetadataReader.read(asset: nil, imageURL: url)
        XCTAssertTrue(metadata.device.isEmpty)
        XCTAssertTrue(metadata.date.isEmpty)
        XCTAssertTrue(metadata.exposure.isEmpty)
        XCTAssertTrue(metadata.location.isEmpty)
    }

    private func makeFixture(includeMetadata: Bool) throws -> URL {
        let width = 1600
        let height = 1000
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.28, green: 0.48, blue: 0.72, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        )!
        var properties: [CFString: Any] = [:]
        if includeMetadata {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: "Xiaomi",
                kCGImagePropertyTIFFModel: "Xiaomi 15 Pro"
            ]
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: "2026:08:24 16:15:01",
                kCGImagePropertyExifFocalLenIn35mmFilm: 24,
                kCGImagePropertyExifFNumber: 1.78,
                kCGImagePropertyExifExposureTime: 0.01,
                kCGImagePropertyExifISOSpeedRatings: [100]
            ]
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 39.907222,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 116.391389,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}

