import Foundation
import Photos

@MainActor
final class WatermarkModel: ObservableObject {
    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var status = "准备中"
    @Published var resultMessage: String?
    @Published var didSucceed = false

    func process(selection: PickedPhoto) async {
        isWorking = true
        progress = 0.05
        status = "读取照片"
        resultMessage = nil
        didSucceed = false
        defer { try? FileManager.default.removeItem(at: selection.imageURL) }

        do {
            let authorized = await PhotoAccess.request(readWrite: selection.isLivePhoto)
            guard authorized else { throw WatermarkError.photoPermissionDenied }
            let asset = selection.localIdentifier.flatMap {
                PHAsset.fetchAssets(withLocalIdentifiers: [$0], options: nil).firstObject
            }
            status = "读取真实拍摄参数"
            let metadata = MetadataReader.read(asset: asset, imageURL: selection.imageURL)
            guard !metadata.device.isEmpty, !metadata.exposure.isEmpty,
                  !metadata.date.isEmpty, !metadata.location.isEmpty else {
                throw WatermarkError.metadataUnavailable
            }

            if selection.isLivePhoto {
                guard let asset else { throw WatermarkError.livePhotoLibraryAccessRequired }
                status = "复制 Live Photo"
                progress = 0.15
                let copy = try await LivePhotoProcessor.duplicate(asset: asset)
                status = "逐帧渲染液态玻璃"
                progress = 0.35
                try await LivePhotoProcessor.applyWatermark(to: copy, metadata: metadata) { [weak self] value in
                    Task { @MainActor in self?.progress = 0.35 + value * 0.6 }
                }
                resultMessage = "已保存新的带水印 Live Photo"
            } else {
                status = "渲染照片"
                progress = 0.4
                try await StillPhotoProcessor.process(imageURL: selection.imageURL,
                                                      asset: asset, metadata: metadata)
                resultMessage = "已保存新的带水印照片"
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
    case photoReadFailed(String), livePhotoLibraryAccessRequired

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
        }
    }
}

enum PhotoAccess {
    static func request(readWrite: Bool) async -> Bool {
        let level: PHAccessLevel = readWrite ? .readWrite : .addOnly
        let status = await PHPhotoLibrary.requestAuthorization(for: level)
        return readWrite ? status == .authorized : (status == .authorized || status == .limited)
    }
}

