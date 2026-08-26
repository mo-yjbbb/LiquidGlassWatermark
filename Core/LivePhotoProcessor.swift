import Photos
import CoreImage
import AVFoundation
import UIKit

enum LivePhotoProcessor {
    static func process(asset: PHAsset?, selectedImageURL: URL, metadata: WatermarkMetadata,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("LGW-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var externalTemporaryFiles: [URL] = []
        defer {
            externalTemporaryFiles.forEach { try? FileManager.default.removeItem(at: $0) }
            try? FileManager.default.removeItem(at: work)
        }
        let sourcePhoto: URL
        let sourceVideo: URL
        if let asset, let pair = try? matchedResources(for: asset) {
            sourcePhoto = try await PhotoResourceLoader.localURL(for: pair.photo)
            externalTemporaryFiles.append(sourcePhoto)
            sourceVideo = try await PhotoResourceLoader.localURL(for: pair.video)
            externalTemporaryFiles.append(sourceVideo)
        } else {
            let extracted = try MotionPhotoExtractor.extract(from: selectedImageURL, to: work)
            sourcePhoto = extracted.photoURL
            sourceVideo = extracted.videoURL
        }
        let renderedPhoto = work.appendingPathComponent("rendered.jpg")
        let renderedVideo = work.appendingPathComponent("rendered.mov")
        let renderer = GlassRenderer(metadata: metadata)
        try renderStill(sourcePhoto, to: renderedPhoto, renderer: renderer)
        progress(0.12)
        try await renderVideo(sourceVideo, to: renderedVideo, renderer: renderer) {
            progress(0.12 + $0 * 0.68)
        }
        let assembled = try await LivePhotoAssembler().makePair(
            photoURL: renderedPhoto, metadataSourceURL: nil,
            videoURL: renderedVideo, in: work
        )
        progress(0.88)
        try await preflight(photoURL: assembled.photoURL, videoURL: assembled.videoURL)
        let identifier = try await save(photoURL: assembled.photoURL, videoURL: assembled.videoURL,
                                        creationDate: asset?.creationDate, location: asset?.location)
        try await verifySavedLivePhoto(localIdentifier: identifier)
        progress(1)
    }

    private static func matchedResources(for asset: PHAsset) throws
        -> (photo: PHAssetResource, video: PHAssetResource) {
        let resources = PHAssetResource.assetResources(for: asset)
        if let photo = resources.first(where: { $0.type == .fullSizePhoto }),
           let video = resources.first(where: { $0.type == .fullSizePairedVideo }) { return (photo, video) }
        if let photo = resources.first(where: { $0.type == .photo }),
           let video = resources.first(where: { $0.type == .pairedVideo }) { return (photo, video) }
        throw WatermarkError.missingResource
    }

    private static func renderStill(_ sourceURL: URL, to outputURL: URL,
                                    renderer: GlassRenderer) throws {
        guard let original = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
            throw WatermarkError.renderFailed
        }
        let longest = max(original.extent.width, original.extent.height)
        let scale = min(1, 4096 / max(longest, 1))
        let source = scale < 1
            ? original.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1
            ])
            : original
        guard let cg = renderer.makeCGImage(renderer.render(source)),
              let data = UIImage(cgImage: cg).jpegData(compressionQuality: 0.96) else {
            throw WatermarkError.renderFailed
        }
        try data.write(to: outputURL, options: .atomic)
    }

    private static func renderVideo(_ sourceURL: URL, to outputURL: URL,
                                    renderer: GlassRenderer,
                                    progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw WatermarkError.renderFailed
        }
        let composition = AVVideoComposition(asset: asset) { request in
            // request.sourceImage has the finite frame extent required by the
            // renderer. clampedToExtent() is intentionally not used here: it
            // creates an infinite CIImage and traps when the renderer builds
            // its integer cache key.
            request.finish(with: renderer.render(request.sourceImage)
                .cropped(to: request.sourceImage.extent), context: nil)
        }
        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mov
        session.videoComposition = composition
        session.shouldOptimizeForNetworkUse = false
        let poller = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
        await withCheckedContinuation { continuation in
            session.exportAsynchronously { continuation.resume() }
        }
        poller.cancel()
        guard session.status == .completed else { throw session.error ?? WatermarkError.renderFailed }
    }

    private static func preflight(photoURL: URL, videoURL: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            _ = PHLivePhoto.request(withResourceFileURLs: [photoURL, videoURL],
                                    placeholderImage: nil, targetSize: .zero,
                                    contentMode: .aspectFit) { livePhoto, info in
                let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue ?? false
                guard !degraded, !resumed else { return }
                resumed = true
                if livePhoto != nil { continuation.resume() }
                else { continuation.resume(throwing: WatermarkError.livePhotoValidationFailed) }
            }
        }
    }

    private static func save(photoURL: URL, videoURL: URL, creationDate: Date?,
                             location: CLLocation?) async throws -> String {
        var localIdentifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: photoURL, options: nil)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: nil)
            request.creationDate = creationDate
            request.location = location
            localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
        }
        guard let localIdentifier else { throw WatermarkError.livePhotoValidationFailed }
        return localIdentifier
    }

    private static func verifySavedLivePhoto(localIdentifier: String) async throws {
        for attempt in 0..<12 {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            if let saved = result.firstObject {
                let resources = PHAssetResource.assetResources(for: saved)
                let hasPhoto = resources.contains { $0.type == .photo || $0.type == .fullSizePhoto }
                let hasVideo = resources.contains { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }
                if saved.mediaSubtypes.contains(.photoLive), hasPhoto, hasVideo { return }
            }
            if attempt < 11 { try await Task.sleep(for: .milliseconds(400 + attempt * 120)) }
        }
        throw WatermarkError.livePhotoValidationFailed
    }
}

