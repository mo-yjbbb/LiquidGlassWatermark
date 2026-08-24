import Foundation
import Photos

@MainActor
final class WatermarkModel: ObservableObject {
    @Published var isWorking = false
    @Published var progress = 0.0
    @Published var status = "准备中"
    @Published var resultMessage: String?
    @Published var didSucceed = false

    func process(localIdentifier: String) async {
        isWorking = true
        progress = 0.05
        status = "读取照片"
        resultMessage = nil
        didSucceed = false

        do {
            let authorized = await PhotoAccess.request()
            guard authorized else { throw WatermarkError.photoPermissionDenied }
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = result.firstObject else { throw WatermarkError.assetUnavailable }
            status = "读取真实拍摄参数"
            let sourceURL = try await PhotoResourceLoader.imageURL(for: asset)
            let metadata = MetadataReader.read(asset: asset, imageURL: sourceURL)
            try? FileManager.default.removeItem(at: sourceURL)
            guard !metadata.device.isEmpty, !metadata.exposure.isEmpty, !metadata.date.isEmpty else {
                throw WatermarkError.metadataUnavailable
            }

            if asset.mediaSubtypes.contains(.photoLive) {
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
                try await StillPhotoProcessor.process(asset: asset, metadata: metadata)
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

    var errorDescription: String? {
        switch self {
        case .photoPermissionDenied: "请在“设置 → App → 液态玻璃水印 → 照片”中选择“完全访问”"
        case .assetUnavailable: "无法读取所选照片，请确认它已从 iCloud 下载"
        case .notLivePhoto: "所选项目不是 Live Photo"
        case .missingResource: "Live Photo 的图片或视频资源不完整"
        case .renderFailed: "渲染或保存失败"
        case .metadataUnavailable: "未读取到完整的设备与曝光参数，已停止处理；截图、社交平台转存图或被清除 EXIF 的照片不能添加参数水印"
        }
    }
}

enum PhotoAccess {
    static func request() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized
    }
}

