import Photos
import CoreImage

enum LivePhotoProcessor {
    static func duplicate(asset: PHAsset) async throws -> PHAsset {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let photo = resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto }),
              let video = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) else {
            throw WatermarkError.missingResource
        }
        let photoURL = try await PhotoResourceLoader.localURL(for: photo)
        let videoURL = try await PhotoResourceLoader.localURL(for: video)
        defer {
            try? FileManager.default.removeItem(at: photoURL)
            try? FileManager.default.removeItem(at: videoURL)
        }

        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let photoOptions = PHAssetResourceCreationOptions()
            photoOptions.originalFilename = photo.originalFilename
            photoOptions.shouldMoveFile = false
            let videoOptions = PHAssetResourceCreationOptions()
            videoOptions.originalFilename = video.originalFilename
            videoOptions.shouldMoveFile = false
            request.addResource(with: .photo, fileURL: photoURL, options: photoOptions)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: videoOptions)
            request.creationDate = asset.creationDate
            request.location = asset.location
            identifier = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let identifier,
              let copy = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw WatermarkError.assetUnavailable
        }
        return copy
    }

    static func applyWatermark(to asset: PHAsset, metadata: WatermarkMetadata,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        var lastError: Error = WatermarkError.renderFailed
        for attempt in 0..<3 {
            do {
                try await applyOnce(identifier: asset.localIdentifier, metadata: metadata, progress: progress)
                return
            } catch {
                lastError = error
                if attempt < 2 { try await Task.sleep(for: .seconds(2 * (attempt + 1))) }
            }
        }
        throw lastError
    }

    private static func applyOnce(identifier: String, metadata: WatermarkMetadata,
                                  progress: @escaping @Sendable (Double) -> Void) async throws {
        let (readyAsset, input) = try await readyInput(for: identifier)
        guard let context = PHLivePhotoEditingContext(livePhotoEditingInput: input) else {
            throw WatermarkError.notLivePhoto
        }
        let renderer = GlassRenderer(metadata: metadata)
        let duration: Double
        if let audiovisualAsset = input.audiovisualAsset {
            duration = (try? await audiovisualAsset.load(.duration))?.seconds ?? 1
        } else {
            duration = 1
        }
        context.frameProcessor = { frame, error in
            guard error?.pointee == nil else { return nil }
            if duration > 0 { progress(min(max(frame.time.seconds / duration, 0), 1)) }
            return renderer.render(frame.image)
        }
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: "com.localwatermark.liquidglass",
            formatVersion: "1.0",
            data: Data("{\"effect\":\"liquid-glass\",\"version\":1}".utf8)
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.saveLivePhoto(to: output, options: nil) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? WatermarkError.renderFailed) }
            }
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: readyAsset).contentEditingOutput = output
        }
    }

    private static func readyInput(for identifier: String) async throws -> (PHAsset, PHContentEditingInput) {
        var lastError: Error = WatermarkError.assetUnavailable
        for attempt in 0..<12 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 700_000_000)
            }
            guard let refreshed = PHAsset.fetchAssets(
                withLocalIdentifiers: [identifier], options: nil
            ).firstObject else { continue }
            do {
                try await warmLivePhoto(refreshed)
                let input = try await refreshed.contentEditingInput()
                if input.livePhoto != nil, input.audiovisualAsset != nil {
                    return (refreshed, input)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func warmLivePhoto(_ asset: PHAsset) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHLivePhotoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestLivePhoto(
                for: asset,
                targetSize: CGSize(width: 720, height: 720),
                contentMode: .aspectFit,
                options: options
            ) { livePhoto, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                } else if livePhoto != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: WatermarkError.assetUnavailable)
                }
            }
        }
    }
}

