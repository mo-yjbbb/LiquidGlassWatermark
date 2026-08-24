import Photos

extension PHAsset {
    func contentEditingInput() async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            requestContentEditingInput(with: options) { input, _ in
                if let input { continuation.resume(returning: input) }
                else { continuation.resume(throwing: WatermarkError.assetUnavailable) }
            }
        }
    }
}

