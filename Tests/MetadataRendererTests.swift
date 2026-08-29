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

    func testEmbeddedMotionPhotoExtraction() throws {
        let url = try makeFixture(includeMetadata: true)
        let motionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: motionURL)
            try? FileManager.default.removeItem(at: directory)
        }
        var combined = try Data(contentsOf: url)
        combined.append(Data([0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70,
                              0x69, 0x73, 0x6f, 0x6d, 0, 0, 0, 0]))
        try combined.write(to: motionURL)
        XCTAssertTrue(MotionPhotoExtractor.containsEmbeddedVideo(at: motionURL))
        let extracted = try MotionPhotoExtractor.extract(from: motionURL, to: directory)
        XCTAssertGreaterThan((try Data(contentsOf: extracted.photoURL)).count, 0)
        XCTAssertEqual(try Data(contentsOf: extracted.videoURL),
                       Data([0, 0, 0, 16, 0x66, 0x74, 0x79, 0x70,
                             0x69, 0x73, 0x6f, 0x6d, 0, 0, 0, 0]))
    }

    func testInfiniteExtentIsRejectedWithoutBuildingCacheKey() {
        let renderer = GlassRenderer(metadata: WatermarkMetadata())
        let infiniteImage = CIImage(color: .black)
        XCTAssertTrue(infiniteImage.extent.isInfinite)
        let result = renderer.render(infiniteImage)
        XCTAssertTrue(result.extent.isInfinite)
    }

    func testApplePrefixIsRemovedFromDisplayedModel() throws {
        let url = try makeFixture(includeMetadata: true,
                                  make: "Apple", model: "Apple iPhone 17 Pro")
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = MetadataReader.read(asset: nil, imageURL: url)
        XCTAssertEqual(metadata.device, "iPhone 17 Pro")
    }

    func testHonorInternalModelResolvesToMarketingName() throws {
        let url = try makeFixture(includeMetadata: true,
                                  make: "HONOR", model: "AAK-AN00")
        defer { try? FileManager.default.removeItem(at: url) }
        let metadata = MetadataReader.read(asset: nil, imageURL: url)
        XCTAssertEqual(metadata.device, "HONOR WIN RT")

        let source = try XCTUnwrap(CIImage(contentsOf: url,
                                           options: [.applyOrientationProperty: true]))
        let renderer = GlassRenderer(metadata: metadata)
        let rendered = try XCTUnwrap(renderer.makeCGImage(renderer.render(source)))
        let attachment = XCTAttachment(image: UIImage(cgImage: rendered))
        attachment.name = "honor-win-rt-liquid-glass-preview"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeFixture(includeMetadata: Bool,
                             make: String = "Xiaomi",
                             model: String = "Xiaomi 15 Pro") throws -> URL {
        let width = 1600
        let height = 1000
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: colorSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.28, green: 0.48, blue: 0.72, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for x in stride(from: 0, to: width, by: 48) {
            let bright = (x / 48).isMultiple(of: 2)
            context.setFillColor(red: bright ? 0.78 : 0.16,
                                 green: bright ? 0.58 : 0.32,
                                 blue: bright ? 0.22 : 0.68, alpha: 0.72)
            context.fill(CGRect(x: x, y: 0, width: 24, height: height))
        }
        context.setLineWidth(6)
        for y in stride(from: 40, to: height, by: 72) {
            context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.32)
            context.move(to: CGPoint(x: 0, y: y))
            context.addCurve(to: CGPoint(x: CGFloat(width), y: CGFloat(y + 20)),
                             control1: CGPoint(x: CGFloat(width) * 0.3, y: CGFloat(y + 36)),
                             control2: CGPoint(x: CGFloat(width) * 0.7, y: CGFloat(y - 20)))
            context.strokePath()
        }
        let image = context.makeImage()!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        )!
        var properties: [CFString: Any] = [:]
        if includeMetadata {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake: make,
                kCGImagePropertyTIFFModel: model
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
