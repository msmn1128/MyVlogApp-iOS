import AVFoundation
import Foundation

/// 書き出しに要る空き容量（Android: ExportSpace.kt）。
///
/// 書き出しは、クリップごとの作業ファイルを作って結合し、結合した動画を写真ライブラリへ取り込む。
/// クリップごとの作業ファイルは結合の直後に消すので、いちばん多く抱えるのは「結合中（作業ファイル＋
/// 結合した動画）」か「写真への取り込み中（結合した動画＋取り込み先）」で、どちらも出来上がりの約2倍。
/// 容量が足りないと、AVFoundationの英語のエラーのまま途中で失敗していた。書き出しの前に見積もって
/// 断り、それでも途中で尽きたときは日本語で知らせる。
nonisolated enum ExportSpace {
    /// 映像のビットレート（ExportWorker.h264Settings と同じ値）。Android の MEDIACODEC_BITRATE_BPS と同じ
    static let videoBitRate: Int64 = 12_000_000
    /// 音声のビットレートの見込み（Android: AUDIO_BITRATE_BPS）。音声は素材のまま結合するので目安
    static let audioBitRate: Int64 = 128_000
    /// 見積もりに足す余裕。タイトルカードなどの細かいファイルと、見積もりの誤差のぶん
    static let marginBytes: Int64 = 200 * 1024 * 1024

    /// 出来上がりの動画の大きさの見積もり（バイト）
    static func estimatedOutputBytes(durationMs: Int64) -> Int64 {
        max(0, durationMs) * (videoBitRate + audioBitRate) / 8 / 1000
    }

    /// 書き出しに要る空き容量（バイト）。いちばん多く抱える瞬間（出来上がりの2倍）で見積もる
    static func requiredFreeBytes(durationMs: Int64) -> Int64 {
        estimatedOutputBytes(durationMs: durationMs) * 2 + marginBytes
    }

    /// 書き出しの長さ（タイトルカード＋各クリップのトリム後の長さ）
    static func exportDurationMs(clips: [VlogClip], includeTitle: Bool) -> Int64 {
        (includeTitle ? Int64(VlogLayout.titleCardDuration * 1000) : 0) + clips.reduce(0) { $0 + $1.trimmedDurationMs }
    }

    /// アプリが使える空き（システムが必要に応じて消せる他のアプリのキャッシュも数える値）。読めなければnil
    static func availableBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static let advice = "不要な動画やアプリを削除するか、クリップを減らしてから書き出してください"

    /// 書き出す前に空き容量が足りないと分かったときの文言。「使える空き」は、設定アプリに出る空きより
    /// 小さいことがあるので、見比べて混乱しないよう「使える空き」と書く
    static func notEnoughSpaceMessage(required: Int64, available: Int64) -> String {
        "端末の空き容量が足りません（書き出しに約\(sizeText(required))必要ですが、"
            + "使える空きは\(sizeText(available))です）。\(advice)"
    }

    /// 書き出しの途中で容量が尽きたときの文言
    static let ranOutOfSpaceMessage = "書き出しの途中で端末の空き容量が足りなくなりました。\(advice)"

    /// 容量不足によるエラーか。AVFoundationは中に元のエラー（NSUnderlyingError）を抱えていることがあるので、たどって見る
    static func isNoSpaceError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let e = current, depth < 5 {
            switch (e.domain, e.code) {
            case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError),
                 (NSPOSIXErrorDomain, Int(ENOSPC)),
                 (AVFoundationErrorDomain, AVError.Code.diskFull.rawValue):
                return true
            default:
                current = e.userInfo[NSUnderlyingErrorKey] as? NSError
                depth += 1
            }
        }
        return false
    }

    /// 「1.4GB」「245MB」のような大きさの表記。1GB未満をGBで出すと差が読み取りにくいのでMBで出す
    static func sizeText(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        return mb >= 1024
            ? String(format: "%.1fGB", locale: Locale(identifier: "en_US_POSIX"), mb / 1024)
            : String(format: "%.0fMB", locale: Locale(identifier: "en_US_POSIX"), mb)
    }
}
