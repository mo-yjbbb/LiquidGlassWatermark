import Photos
import CoreImage
import UIKit

enum StillPhotoProcessor {
    static func process(imageURL: URL, asset: PHAsset?, metadata: WatermarkMetadata) async throws {
        guard let original = CIImage(contentsOf: imageURL, options: [.applyOrientationProperty: true]) else {
            throw WatermarkError.assetUnavailable
        }
        let longest = max(original.extent.width, original.extent.height)
        let scale = min(1, 4096 / max(longest, 1))
        let ciImage = scale < 1
            ? original.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ])
            : original
        let renderer = GlassRenderer(metadata: metadata)
        guard let cgImage = renderer.makeCGImage(renderer.render(ciImage)) else { throw WatermarkError.renderFailed }
        let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.96)
        guard let data else { throw WatermarkError.renderFailed }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            request.creationDate = asset?.creationDate
            request.location = asset?.location
        }
    }
}

