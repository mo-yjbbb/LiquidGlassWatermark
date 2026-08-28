import Photos
import CoreImage
import UIKit
import ImageIO
import UniformTypeIdentifiers

enum StillPhotoProcessor {
    @discardableResult
    static func process(imageURL: URL, asset: PHAsset?, metadata: WatermarkMetadata,
                        maxDimension: CGFloat = 4096) async throws -> String {
        guard let original = CIImage(contentsOf: imageURL, options: [.applyOrientationProperty: true]) else {
            throw WatermarkError.assetUnavailable
        }
        let longest = max(original.extent.width, original.extent.height)
        let scale = min(1, maxDimension / max(longest, 1))
        let ciImage = scale < 1
            ? original.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ])
            : original
        let renderer = GlassRenderer(metadata: metadata)
        guard let cgImage = renderer.makeCGImage(renderer.render(ciImage)) else { throw WatermarkError.renderFailed }
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        try writeJPEG(cgImage, metadataSourceURL: imageURL, to: outputURL)
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: outputURL, options: nil)
            request.creationDate = asset?.creationDate
            request.location = asset?.location
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let identifier else { throw WatermarkError.renderFailed }
        return identifier
    }

    private static func writeJPEG(_ image: CGImage, metadataSourceURL: URL,
                                  to outputURL: URL) throws {
        var properties: [CFString: Any] = [:]
        if let source = CGImageSourceCreateWithURL(metadataSourceURL as CFURL, nil),
           let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = original
        }
        properties[kCGImagePropertyOrientation] = 1
        properties.removeValue(forKey: kCGImagePropertyPixelWidth)
        properties.removeValue(forKey: kCGImagePropertyPixelHeight)
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality] = 0.96
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw WatermarkError.renderFailed }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw WatermarkError.renderFailed }
    }
}
