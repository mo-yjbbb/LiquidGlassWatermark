import UIKit
import Photos
import UniformTypeIdentifiers
import AVFoundation

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
            let authorized = await PhotoAccess.request(readWrite: false)
            guard authorized else { throw WatermarkError.photoPermissionDenied }

            if let movieURL = payload.videoURL {
                await setStatus("正在重建 Live Photo", progress: 0.12)
                try await LivePhotoProcessor.process(
                    sharedPhotoURL: payload.photoURL, pairedVideoURL: movieURL,
                    metadata: metadata
                ) { [weak self] value in
                    Task { @MainActor in
                        self?.setStatus("正在处理 Live Photo", progress: Float(0.12 + value * 0.86))
                    }
                }
            } else {
                await setStatus("正在渲染照片", progress: 0.35)
                try await StillPhotoProcessor.process(imageURL: payload.photoURL,
                                                      asset: nil, metadata: metadata)
            }
            await setStatus(payload.videoURL == nil ? "已保存带水印照片" : "已保存带水印 Live Photo",
                            progress: 1)
            try? await Task.sleep(for: .milliseconds(650))
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
}

private struct SharedPhotoPayload {
    let photoURL: URL
    let videoURL: URL?
}

private enum SharedPhotoLoader {
    static func load(from providers: [NSItemProvider]) async throws -> SharedPhotoPayload {
        guard !providers.isEmpty else { throw WatermarkError.assetUnavailable }
        var photoURL: URL?
        var videoURL: URL?

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
        guard let photoURL else { throw WatermarkError.assetUnavailable }
        return SharedPhotoPayload(photoURL: photoURL, videoURL: videoURL)
    }

    private static func copyFile(from provider: NSItemProvider, type: String,
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
}
