import UIKit
import Photos
import UniformTypeIdentifiers
import AVFoundation
import ImageIO

final class ShareViewController: UIViewController {
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let cancelButton = UIButton(type: .system)
    private var workTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()
        workTask = Task { await processSharedItem() }
    }

    deinit { workTask?.cancel() }

    private func configureUI() {
        view.backgroundColor = .systemBackground
        titleLabel.text = "液态玻璃水印"
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textAlignment = .center
        statusLabel.text = "正在读取所选照片…"
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleLabel, statusLabel, progressView, cancelButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func cancel() {
        workTask?.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @MainActor
    private func setStatus(_ text: String, progress: Float? = nil) {
        statusLabel.text = text
        if let progress { progressView.setProgress(progress, animated: true) }
    }

    private func processSharedItem() async {
        do {
            let providers = extensionContext?.inputItems
                .compactMap { $0 as? NSExtensionItem }
                .compactMap(\.attachments)
                .flatMap { $0 } ?? []
            let payload = try await SharedPhotoLoader.load(from: providers)
            defer {
                try? FileManager.default.removeItem(at: payload.photoURL)
                if let videoURL = payload.videoURL {
                    try? FileManager.default.removeItem(at: videoURL)
                }
            }
            try Task.checkCancellation()
            await setStatus("读取真实拍摄参数", progress: 0.08)
            let metadata = MetadataReader.read(asset: nil, imageURL: payload.photoURL)
            guard !metadata.device.isEmpty, !metadata.exposure.isEmpty,
                  !metadata.date.isEmpty, !metadata.location.isEmpty else {
                throw WatermarkError.metadataUnavailable
            }
            let authorized = await PhotoAccess.request(readWrite: true)
            guard authorized else { throw WatermarkError.photoPermissionDenied }

            let original = SharedAssetMatcher.find(photoURL: payload.photoURL,
                                                   requiresLive: payload.isLivePhoto)
            if payload.isLivePhoto, original == nil, payload.videoURL == nil {
                throw WatermarkError.livePhotoLibraryAccessRequired
            }
            let saveMode = await chooseSaveMode(canReplace: original != nil)
            guard let saveMode else { throw CancellationError() }

            let newIdentifier: String
            if payload.isLivePhoto, let original {
                await setStatus("正在读取 Live Photo 配对资源", progress: 0.12)
                newIdentifier = try await LivePhotoProcessor.process(
                    asset: original, selectedImageURL: payload.photoURL,
                    metadata: metadata, maxStillDimension: 2048
                ) { [weak self] value in
                    Task { @MainActor in
                        self?.setStatus("正在处理 Live Photo", progress: Float(0.12 + value * 0.86))
                    }
                }
            } else if let movieURL = payload.videoURL {
                await setStatus("正在重建 Live Photo", progress: 0.12)
                newIdentifier = try await LivePhotoProcessor.process(
                    sharedPhotoURL: payload.photoURL, pairedVideoURL: movieURL,
                    metadata: metadata, creationDate: original?.creationDate,
                    location: original?.location, maxStillDimension: 2048
                ) { [weak self] value in
                    Task { @MainActor in
                        self?.setStatus("正在处理 Live Photo", progress: Float(0.12 + value * 0.86))
                    }
                }
            } else {
                await setStatus("正在渲染照片", progress: 0.35)
                newIdentifier = try await StillPhotoProcessor.process(imageURL: payload.photoURL,
                                                      asset: original, metadata: metadata,
                                                      maxDimension: 2048)
            }
            await setStatus("正在确认图库结果", progress: 0.96)
            // A copied asset that keeps the original PHAsset creation date is
            // inserted years back in Recents, which looks exactly like a
            // failed save from the Photos share sheet. Keep the embedded EXIF
            // capture date for the watermark/metadata, but place a new copy at
            // the current library date so it is immediately visible.
            if saveMode == .newCopy {
                try await SharedSaveVerifier.makeVisibleInRecents(identifier: newIdentifier)
            }
            try await SharedSaveVerifier.verifyAndFile(identifier: newIdentifier,
                                                        requiresLive: payload.isLivePhoto)
            if saveMode == .replaceOriginal, let original {
                await setStatus("正在替换原图", progress: 0.98)
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets([original] as NSArray)
                }
            }
            await setStatus(payload.isLivePhoto
                            ? "已保存到最近项目顶部和“液态玻璃水印”相簿（Live Photo）"
                            : "已保存到最近项目顶部和“液态玻璃水印”相簿",
                            progress: 1)
            try? await Task.sleep(for: .milliseconds(1200))
            extensionContext?.completeRequest(returningItems: nil)
        } catch is CancellationError {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        } catch {
            await setStatus(error.localizedDescription)
            await MainActor.run {
                cancelButton.setTitle("关闭", for: .normal)
                progressView.progressTintColor = .systemRed
            }
        }
    }

    @MainActor
    private func chooseSaveMode(canReplace: Bool) async -> WatermarkModel.SaveMode? {
        await withCheckedContinuation { (continuation: CheckedContinuation<WatermarkModel.SaveMode?, Never>) in
            let alert = UIAlertController(title: "如何保存处理结果？",
                                          message: "覆盖原图会在确认新资源完整保存后删除原始照片。",
                                          preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: "保存为新照片", style: .default) { _ in
                continuation.resume(returning: .newCopy)
            })
            if canReplace {
                alert.addAction(UIAlertAction(title: "覆盖原图", style: .destructive) { _ in
                    continuation.resume(returning: .replaceOriginal)
                })
            }
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in
                continuation.resume(returning: nil)
            })
            if let popover = alert.popoverPresentationController {
                popover.sourceView = self.view
                popover.sourceRect = CGRect(x: self.view.bounds.midX,
                                            y: self.view.bounds.maxY - 1,
                                            width: 1, height: 1)
            }
            present(alert, animated: true)
        }
    }
}

private struct SharedPhotoPayload {
    let photoURL: URL
    let videoURL: URL?
    let isLivePhoto: Bool
}

private enum SharedPhotoLoader {
    static func load(from providers: [NSItemProvider]) async throws -> SharedPhotoPayload {
        guard !providers.isEmpty else { throw WatermarkError.assetUnavailable }
        var photoURL: URL?
        var videoURL: URL?
        let advertisedLive = providers.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier)
        }

        // Some Photos versions expose a Live Photo as a file package instead
        // of separate image/movie representations.
        for provider in providers where
            provider.hasItemConformingToTypeIdentifier(UTType.livePhoto.identifier) {
            if let package = try? await copyFile(from: provider,
                                                 type: UTType.livePhoto.identifier,
                                                 fallbackExtension: "livephoto"),
               let pair = pairInsidePackage(package) {
                photoURL = pair.photo
                videoURL = pair.video
                break
            }
        }

        // Photos may expose a Live Photo as two attachments or as one provider
        // advertising both image and QuickTime movie. Inspect every provider.
        for provider in providers {
            if photoURL == nil,
               provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                photoURL = try? await copyFile(from: provider, type: UTType.image.identifier,
                                               fallbackExtension: "heic")
            }
            if videoURL == nil,
               provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                videoURL = try? await copyFile(from: provider, type: UTType.movie.identifier,
                                               fallbackExtension: "mov")
            }
            if videoURL == nil,
               provider.hasItemConformingToTypeIdentifier(UTType.quickTimeMovie.identifier) {
                videoURL = try? await copyFile(from: provider,
                                               type: UTType.quickTimeMovie.identifier,
                                               fallbackExtension: "mov")
            }
        }
        guard var photoURL else { throw WatermarkError.assetUnavailable }

        // Xiaomi, Samsung, Google and other vendors commonly share a Motion
        // Photo as one JPEG/HEIC with an MP4 appended to it. Photos does not
        // advertise those files as UTType.livePhoto, so recover the pair here
        // instead of silently treating it as a still image.
        if videoURL == nil, MotionPhotoExtractor.containsEmbeddedVideo(at: photoURL) {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("LGW-SharedMotion-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let embedded = try MotionPhotoExtractor.extract(from: photoURL, to: directory)
            try? FileManager.default.removeItem(at: photoURL)
            photoURL = embedded.photoURL
            videoURL = embedded.videoURL
        }
        return SharedPhotoPayload(photoURL: photoURL, videoURL: videoURL,
                                  isLivePhoto: advertisedLive || videoURL != nil)
    }

    private static func pairInsidePackage(_ url: URL) -> (photo: URL, video: URL)? {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url,
                    includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
        let files = enumerator.compactMap { $0 as? URL }
        let photo = files.first { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        let video = files.first { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true }
        guard let photo, let video else { return nil }
        return (photo, video)
    }

    private static func copyFile(from provider: NSItemProvider, type: String,
                                 fallbackExtension: String) async throws -> URL {
        if let copied = try? await copyTemporaryRepresentation(from: provider, type: type,
                                                               fallbackExtension: fallbackExtension) {
            return copied
        }
        if let copied = try? await copyInPlaceRepresentation(from: provider, type: type,
                                                             fallbackExtension: fallbackExtension) {
            return copied
        }
        return try await copyDataRepresentation(from: provider, type: type,
                                                fallbackExtension: fallbackExtension)
    }

    private static func copyTemporaryRepresentation(from provider: NSItemProvider, type: String,
                                                     fallbackExtension: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { source, error in
                if let error { continuation.resume(throwing: error); return }
                guard let source else {
                    continuation.resume(throwing: WatermarkError.assetUnavailable); return
                }
                let ext = source.pathExtension.isEmpty ? fallbackExtension : source.pathExtension
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                do {
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: destination)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func copyInPlaceRepresentation(from provider: NSItemProvider, type: String,
                                                   fallbackExtension: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { source, _, error in
                if let error { continuation.resume(throwing: error); return }
                guard let source else {
                    continuation.resume(throwing: WatermarkError.assetUnavailable); return
                }
                let ext = source.pathExtension.isEmpty ? fallbackExtension : source.pathExtension
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                do {
                    let accessed = source.startAccessingSecurityScopedResource()
                    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
                    try FileManager.default.copyItem(at: source, to: destination)
                    continuation.resume(returning: destination)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func copyDataRepresentation(from provider: NSItemProvider, type: String,
                                                fallbackExtension: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { continuation.resume(throwing: error); return }
                guard let data, !data.isEmpty else {
                    continuation.resume(throwing: WatermarkError.assetUnavailable); return
                }
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(fallbackExtension)
                do {
                    try data.write(to: destination, options: .atomic)
                    continuation.resume(returning: destination)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private enum SharedAssetMatcher {
    static func find(photoURL: URL, requiresLive: Bool) -> PHAsset? {
        guard let source = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let dateText = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = formatter.date(from: dateText) else { return nil }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@",
                                        date.addingTimeInterval(-2) as NSDate,
                                        date.addingTimeInterval(2) as NSDate)
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var match: PHAsset?
        result.enumerateObjects { asset, _, stop in
            if !requiresLive || asset.mediaSubtypes.contains(.photoLive) {
                match = asset
                stop.pointee = true
            }
        }
        return match
    }
}

private enum SharedSaveVerifier {
    private static let albumName = "液态玻璃水印"

    static func verifyAndFile(identifier: String, requiresLive: Bool) async throws {
        let asset = try await waitForAsset(identifier: identifier, requiresLive: requiresLive)
        let album = try await fetchOrCreateAlbum()
        try await PHPhotoLibrary.shared().performChanges {
            guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
            request.addAssets([asset] as NSArray)
        }
        // Confirm album membership as well; success must mean the result is
        // discoverable, not merely that Photos accepted a change request.
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localIdentifier == %@", identifier)
        guard PHAsset.fetchAssets(in: album, options: options).firstObject != nil else {
            throw WatermarkError.livePhotoValidationFailed
        }
    }

    static func makeVisibleInRecents(identifier: String) async throws {
        let asset = try await waitForAsset(identifier: identifier, requiresLive: false)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest(for: asset).creationDate = Date()
        }
        guard let refreshed = PHAsset.fetchAssets(withLocalIdentifiers: [identifier],
                                                  options: nil).firstObject,
              let date = refreshed.creationDate,
              abs(date.timeIntervalSinceNow) < 60 else {
            throw WatermarkError.renderFailed
        }
    }

    private static func waitForAsset(identifier: String, requiresLive: Bool) async throws -> PHAsset {
        for attempt in 0..<12 {
            if let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
                if !requiresLive { return asset }
                let resources = PHAssetResource.assetResources(for: asset)
                let hasPhoto = resources.contains { $0.type == .photo || $0.type == .fullSizePhoto }
                let hasVideo = resources.contains { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }
                if asset.mediaSubtypes.contains(.photoLive), hasPhoto, hasVideo { return asset }
            }
            if attempt < 11 { try await Task.sleep(for: .milliseconds(350 + attempt * 120)) }
        }
        throw WatermarkError.livePhotoValidationFailed
    }

    private static func fetchOrCreateAlbum() async throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", albumName)
        if let existing = PHAssetCollection.fetchAssetCollections(with: .album,
                subtype: .albumRegular, options: options).firstObject { return existing }
        var identifier: String?
        try await PHPhotoLibrary.shared().performChanges {
            identifier = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: albumName)
                .placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let identifier,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier],
                    options: nil).firstObject else { throw WatermarkError.renderFailed }
        return album
    }
}

