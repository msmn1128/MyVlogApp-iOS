import Foundation
import Photos

/// クリップの動画が、いまも開けるか（Android: MediaAccess.isReadable）。
///
/// 復元（VlogStore.validClips）・開けない動画の目印（refreshMissingClips）・書き出し前の確認
/// （ExportManager）が同じ判定を使う。ファイル取り込みはDocumentsのコピーがあるか、
/// フォトライブラリ由来はPHAssetがあるか（いまのアクセス範囲で見えるか）で見る。
/// フォトライブラリの確認は、1件ずつ引くと件数ぶん（最大100本）往復するので、まとめて1回で引く。
nonisolated enum ClipAvailability {

    /// 開けないクリップの添字（並び順のまま）
    static func unavailableIndices(in clips: [VlogClip]) -> [Int] {
        let existingAssets = existingAssetIdentifiers(among: clips.compactMap(\.assetIdentifier))
        return clips.indices.filter { !isAvailable(clips[$0], existingAssets: existingAssets) }
    }

    /// `existingAssets`は`existingAssetIdentifiers`でまとめて引いた結果
    static func isAvailable(_ clip: VlogClip, existingAssets: Set<String>) -> Bool {
        if let url = clip.resolvedFileURL, FileManager.default.fileExists(atPath: url.path) { return true }
        if let id = clip.assetIdentifier, existingAssets.contains(id) { return true }
        return false
    }

    /// 渡した識別子のうち、いまもフォトライブラリに実在するものだけを返す（1回のfetchで済ませる）
    static func existingAssetIdentifiers(among identifiers: [String]) -> Set<String> {
        guard !identifiers.isEmpty else { return [] }
        var found: Set<String> = []
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
            .enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
        return found
    }
}
