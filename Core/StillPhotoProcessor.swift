import Photos
import CoreImage
import UIKit

enum StillPhotoProcessor {
    static func process(asset: PHAsset, metadata: WatermarkMetadata) async throws {
        let input = try await asset.contentEditingInput()
        guard let url = input.fullSizeImageURL,
              let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw WatermarkError.assetUnavailable
        }
        let renderer = GlassRenderer(metadata: metadata)
        guard let cgImage = renderer.makeCGImage(renderer.render(ciImage)) else { throw WatermarkError.renderFailed }
        let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.96)
        guard let data else { throw WatermarkError.renderFailed }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            request.creationDate = asset.creationDate
            request.location = asset.location
        }
    }
}

