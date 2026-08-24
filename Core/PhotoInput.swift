import Photos

enum PhotoResourceLoader {
    static func imageURL(for asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo }) else {
            throw WatermarkError.missingResource
        }
        return try await localURL(for: resource)
    }

    static func localURL(for resource: PHAssetResource) async throws -> URL {
        let ext = (resource.originalFilename as NSString).pathExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "img" : ext)
        var lastError: Error = WatermarkError.assetUnavailable
        for attempt in 0..<4 {
            try? FileManager.default.removeItem(at: url)
            do {
                try await write(resource, to: url)
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size > 0 else {
                    throw WatermarkError.assetUnavailable
                }
                return url
            } catch {
                lastError = error
                if attempt < 3 { try await Task.sleep(for: .milliseconds(700 * (attempt + 1))) }
            }
        }
        throw lastError
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

extension PHAsset {
    func contentEditingInput() async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            options.canHandleAdjustmentData = { _ in false }
            requestContentEditingInput(with: options) { input, _ in
                if let input { continuation.resume(returning: input) }
                else { continuation.resume(throwing: WatermarkError.assetUnavailable) }
            }
        }
    }
}

