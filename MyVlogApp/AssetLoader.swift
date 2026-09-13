import AVFoundation
import Photos

/// Loads AVAsset from either a PHAsset identifier or a file URL, with an in-memory cache.
actor AssetLoader {
    static let shared = AssetLoader()

    private var cache: [String: AVAsset] = [:]

    func load(clip: VlogClip) async throws -> AVAsset {
        let key = cacheKey(for: clip)
        if let cached = cache[key] { return cached }

        let asset: AVAsset
        if let identifier = clip.assetIdentifier {
            asset = try await loadFromPHAsset(identifier: identifier)
        } else if let url = clip.resolvedFileURL {
            asset = AVURLAsset(url: url)
        } else {
            throw AssetLoaderError.noReference
        }
        cache[key] = asset
        return asset
    }

    func invalidate(clip: VlogClip) {
        cache.removeValue(forKey: cacheKey(for: clip))
    }

    func clearAll() {
        cache.removeAll()
    }

    private func cacheKey(for clip: VlogClip) -> String {
        clip.assetIdentifier ?? clip.resolvedFileURL?.absoluteString ?? clip.id.uuidString
    }

    private func loadFromPHAsset(identifier: String) async throws -> AVAsset {
        let options = PHFetchOptions()
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: options)
        guard let phAsset = result.firstObject else {
            throw AssetLoaderError.assetNotFound(identifier)
        }
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false

            let requestOptions = PHVideoRequestOptions()
            requestOptions.isNetworkAccessAllowed = true
            requestOptions.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: phAsset, options: requestOptions) { asset, _, info in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }

                if let asset {
                    hasResumed = true
                    continuation.resume(returning: asset)
                } else {
                    let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if !isDegraded {
                        hasResumed = true
                        let err = (info?[PHImageErrorKey] as? Error) ?? AssetLoaderError.assetNotFound(identifier)
                        continuation.resume(throwing: err)
                    }
                }
            }
        }
    }
}

enum AssetLoaderError: LocalizedError {
    case noReference
    case assetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .noReference:         return "クリップに参照がありません"
        case .assetNotFound(let id): return "動画が見つかりません: \(id)"
        }
    }
}
