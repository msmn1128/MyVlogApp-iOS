import UIKit
import AVFoundation
import Photos

/// クリップのサムネイル画像をキャッシュ付きで読み込む（AssetLoader/WaveformExtractorと
/// 同じ設計：actor + UUIDキーのキャッシュ）。
/// 以前はTimelineView.ClipTile.loadThumbnailが毎回PHImageManager/
/// AVAssetImageGeneratorへ直接リクエストしており、クリップ一覧をスクロールして
/// 再表示されるたびに同じ画像を再デコードしていた。
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private var cache: [UUID: UIImage] = [:]

    func thumbnail(for clip: VlogClip, size: CGSize) async -> UIImage? {
        if let cached = cache[clip.id] { return cached }
        let image = await load(for: clip, size: size)
        if let image { cache[clip.id] = image }
        return image
    }

    private func load(for clip: VlogClip, size: CGSize) async -> UIImage? {
        if let identifier = clip.assetIdentifier {
            return await loadFromPHAsset(identifier: identifier, size: size)
        } else if clip.resolvedFileURL != nil {
            return await loadFromFile(clip: clip)
        }
        return nil
    }

    private func loadFromPHAsset(identifier: String, size: CGSize) async -> UIImage? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        let opts = PHImageRequestOptions()
        // キャッシュに載せる最終的な1枚だけが欲しいので.opportunistic（低画質版→高画質版の
        // 2回コールバック）ではなく.highQualityFormat（1回だけ）にする
        opts.deliveryMode = .highQualityFormat
        opts.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: .aspectFill, options: opts
            ) { img, _ in
                continuation.resume(returning: img)
            }
        }
    }

    /// ファイルインポートのクリップは、波形と同じAVAssetLoaderのキャッシュ済みアセットを
    /// 再利用する（タイルと波形で同じ動画を2重にデコードしないように）
    private func loadFromFile(clip: VlogClip) async -> UIImage? {
        guard let asset = try? await AssetLoader.shared.load(clip: clip) else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cgImage = try? await gen.image(at: time).image else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
