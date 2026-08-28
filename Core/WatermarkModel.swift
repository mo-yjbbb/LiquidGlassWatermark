import Foundation
import Photos

@MainActor
final class WatermarkModel: ObservableObject {
    enum SaveMode { case newCopy, replaceOriginal }
    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var status = "准备中"
    @Published var resultMessage: String?
    @Published var didSucceed = false

    func process(selection: PickedPhoto, saveMode: SaveMode) async {
        isWorking = true
        progress = 0.05
        status = "读取照片"
        resultMessage = nil
        didSucceed = false
        defer { try? FileManager.default.removeItem(at: selection.imageURL) }

        do {
            // Resolve the real PHAsset only after authorization. Classifying in
            // PHPicker's callback can incorrectly turn a Live Photo into a
            // still when the library was not readable yet.
            let authorized = await PhotoAccess.request(readWrite: true)
            guard authorized else { throw WatermarkError.photoPermissionDenied }
            let asset = selection.localIdentifier.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
            }
            let resources = asset.map { PHAssetResource.assetResources(for: $0) } ?? []
            let actualIsLive = selection.isLivePhoto
                || asset?.mediaSubtypes.contains(.photoLive) == true
                || resources.contains(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo })
                || MotionPhotoExtractor.containsEmbeddedVideo(at: selection.imageURL)
            status = "读取真实拍摄参数"
            let metadata = MetadataReader.read(asset: asset, imageURL: selection.imageURL)
            guard !metadata.device.isEmpty, !metadata.exposure.isEmpty,
                  !metadata.date.isEmpty, !metadata.location.isEmpty else {
                throw WatermarkError.metadataUnavailable
            }

            if actualIsLive {
                status = "重建标准 Live Photo"
                progress = 0.15
                _ = try await LivePhotoProcessor.process(asset: asset,
                                                     selectedImageURL: selection.imageURL,
                                                     metadata: metadata) { [weak self] value in
                    Task { @MainActor in self?.progress = 0.15 + value * 0.8 }
                }
                resultMessage = "已保存新的带水印 Live Photo"
            } else {
                status = "渲染照片"
                progress = 0.4
                _ = try await StillPhotoProcessor.process(imageURL: selection.imageURL,
                                                      asset: asset, metadata: metadata)
                resultMessage = "已保存新的带水印照片"
            }
            if saveMode == .replaceOriginal, let asset {
                status = "替换原图"
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets([asset] as NSArray)
                }
                resultMessage = actualIsLive ? "已用带水印 Live Photo 替换原图" : "已用带水印照片替换原图"
            }
            progress = 1
            status = "完成"
            didSucceed = true
        } catch {
            resultMessage = error.localizedDescription
        }
        isWorking = false
    }
}

enum WatermarkError: LocalizedError {
    case photoPermissionDenied, assetUnavailable, notLivePhoto, missingResource, renderFailed, metadataUnavailable
    case photoReadFailed(String), livePhotoLibraryAccessRequired, livePhotoValidationFailed

    var errorDescription: String? {
        switch self {
        case .photoPermissionDenied: "请在“设置 → App → 液态玻璃水印 → 照片”中选择“完全访问”"
        case .assetUnavailable: "照片资源暂时不可用"
        case .notLivePhoto: "所选项目不是 Live Photo"
        case .missingResource: "Live Photo 的图片或视频资源不完整"
        case .renderFailed: "渲染或保存失败"
        case .metadataUnavailable: "照片缺少机型、时间、摄像参数或位置，无法生成完整参数水印"
        case .photoReadFailed(let detail): "读取原图失败：\(detail)"
        case .livePhotoLibraryAccessRequired: "无法访问所选 Live Photo 的视频资源，请授予照片完全访问权限"
        case .livePhotoValidationFailed: "输出没有保留完整的 Live Photo 图片和配对视频，已判定处理失败"
        }
    }
}

enum PhotoAccess {
    static func request(readWrite: Bool) async -> Bool {
        let level: PHAccessLevel = readWrite ? .readWrite : .addOnly
        let status = await PHPhotoLibrary.requestAuthorization(for: level)
        return readWrite
            ? (status == .authorized || status == .limited)
            : (status == .authorized || status == .limited)
    }
}
