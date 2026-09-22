import AVFoundation
import Photos

/// Loads AVAsset from either a PHAsset identifier or a file URL, with an in-memory cache.
actor AssetLoader {
    static let shared = AssetLoader()

    private var cache: [String: AVAsset] = [:]

    /// - Parameter forPreview: true ならプレビュー再生・波形抽出・サムネイル用の軽量リクエストにする
    ///   （書き出し側の最終出力は1920x1080に収まるため、フォトライブラリ由来のクリップでそれ以上の
    ///   画質をプレビューのためだけに取りに行く必要がない）。false（書き出し側の既定）では
    ///   従来どおり最高画質を要求する。
    ///
    ///   4K/60p等の大きいiCloud最適化済み素材は、.highQualityFormatだとオリジナルの
    ///   フルサイズファイルをまるごとダウンロードしてからでないとAVAssetが返らず、
    ///   プレビューを開くたびに数秒〜それ以上待たされることがあった。プレビュー用途を
    ///   .mediumQualityFormatに分けることで、その場で使うぶんだけの軽い書き出し版を
    ///   Photos側に用意してもらい、読み込みを速くする。
    ///   プレビュー用とエクスポート用でキャッシュキーを分けているのは、プレビューで
    ///   取得した軽量版がキャッシュに乗ったままエクスポート時に再利用されて
    ///   書き出し画質が落ちる事故を防ぐため。
    func load(clip: VlogClip, forPreview: Bool = false) async throws -> AVAsset {
        let key = cacheKey(for: clip, forPreview: forPreview)
        if let cached = cache[key] { return cached }

        let asset: AVAsset
        if let identifier = clip.assetIdentifier {
            asset = try await loadFromPHAsset(identifier: identifier, forPreview: forPreview)
        } else if let url = clip.resolvedFileURL {
            asset = AVURLAsset(url: url)
        } else {
            throw AssetLoaderError.noReference
        }
        cache[key] = asset
        return asset
    }

    /// タイムラインに残っていない素材のAVAssetを捨てる（VlogStore.releaseUnusedMediaCaches）。
    /// AVAssetはデコーダや読み取り中のファイルハンドルを抱えるため、削除したクリップの分を
    /// 持ち続けるとメモリが戻らない。
    /// - Parameter keys: いまタイムラインにあるクリップの`VlogClip.mediaCacheKey`
    func retain(only keys: Set<String>) {
        cache = cache.filter { key, _ in keys.contains(Self.baseKey(of: key)) }
    }

    /// 書き出し用に開いたAVAssetだけを捨てる（ExportManager.runExportの後始末から呼ぶ）。
    ///
    /// 書き出し用は最高画質を要求したAVAssetで、デコーダと読み取り中のファイルハンドルを抱える。
    /// タイムラインに残っている限り`retain(only:)`では落ちないため、書き出しが終わったら
    /// クリップ数ぶん抱えたままになる。プレビュー用は残すので、直後の操作感は変わらない。
    func releaseExportAssets() {
        cache = cache.filter { key, _ in key.hasPrefix(Self.previewPrefix) }
    }

    private static let previewPrefix = "preview:"

    /// プレビュー用キーから素材の識別子部分を取り出す（`retain(only:)`の突き合わせ用）
    private static func baseKey(of cacheKey: String) -> String {
        cacheKey.hasPrefix(previewPrefix) ? String(cacheKey.dropFirst(previewPrefix.count)) : cacheKey
    }

    private func cacheKey(for clip: VlogClip, forPreview: Bool) -> String {
        forPreview ? Self.previewPrefix + clip.mediaCacheKey : clip.mediaCacheKey
    }

    private func loadFromPHAsset(identifier: String, forPreview: Bool) async throws -> AVAsset {
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
            requestOptions.deliveryMode = forPreview ? .mediumQualityFormat : .highQualityFormat
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
