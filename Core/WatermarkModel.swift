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

            if asset.mediaSubtypes.contains(.photoLive) {
                status = "复制 Live Photo"
                progress = 0.15
                let copy = try await LivePhotoProcessor.duplicate(asset: asset)
                status = "逐帧渲染液态玻璃"
                progress = 0.35
                try await LivePhotoProcessor.applyWatermark(to: copy) { [weak self] value in
                    Task { @MainActor in self?.progress = 0.35 + value * 0.6 }
                }
                resultMessage = "已保存新的带水印 Live Photo"
            } else {
                status = "渲染照片"
                progress = 0.4
                try await StillPhotoProcessor.process(asset: asset)
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
    case photoPermissionDenied, assetUnavailable, notLivePhoto, missingResource, renderFailed

    var errorDescription: String? {
        switch self {
        case .photoPermissionDenied: "需要允许访问照片图库"
        case .assetUnavailable: "无法读取所选照片，请确认它已从 iCloud 下载"
        case .notLivePhoto: "所选项目不是 Live Photo"
        case .missingResource: "Live Photo 的图片或视频资源不完整"
        case .renderFailed: "渲染或保存失败"
        }
    }
}

enum PhotoAccess {
    static func request() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }
}

