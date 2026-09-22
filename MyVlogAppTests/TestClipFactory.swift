import Foundation
@testable import MyVlogApp

// =====================================================================================
// テスト用のVlogClip組み立てヘルパー。
//
// VlogClipは必須の引数が多く、各テストで全部書くと「何を確かめたいのか」が埋もれるため、
// 検証に関係ない値（表示用の文字列や解像度）は既定値でまとめて埋める。
// =====================================================================================

enum TestClip {
    /// - Parameter endMs: 省略すると全区間選択（= durationMs）
    static func make(
        durationMs: Int64 = 10_000,
        startMs: Int64 = 0,
        endMs: Int64? = nil,
        texts: [TextSegment] = [TextSegment()],
        shotAtMillis: Int64 = 0,
        timeText: String = "10:00",
        dateText: String = "2026/09/20"
    ) -> VlogClip {
        VlogClip(
            timeText: timeText,
            dateText: dateText,
            durationMs: durationMs,
            width: 1920,
            height: 1080,
            texts: texts,
            startMs: startMs,
            endMs: endMs ?? durationMs,
            shotAtMillis: shotAtMillis
        )
    }

    /// 「先頭は0」の不変条件を満たす区間の並びを、開始位置と文言の組から作る
    static func segments(_ pairs: [(Int64, String)]) -> [TextSegment] {
        pairs.map { TextSegment(startMs: $0.0, text: $0.1) }
    }
}
