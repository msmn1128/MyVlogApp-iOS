import Foundation

// =====================================================================================
// 再生の判断だけを担う純粋関数（Android: playback/PlaybackController.kt の playFromWhere）。
//
// VideoPlayerManagerは@MainActorでAVPlayerを抱えるため単体テストから触れない。
// 「どこから再生するか」の判断はAVPlayerと無関係に決まるので、ここへ切り出して
// テストできるようにしてある（MyVlogAppTests/PlaybackRulesTests.swift）。
// =====================================================================================

/// 再生位置が「クリップの終わりで止まっている」とみなす許容幅（ミリ秒）。
///
/// 終わりで止めたときの位置は、トリミング終端（メタデータから取った尺が基準）と
/// AVPlayerが実際に止まれる位置とで数ミリ秒ずれることがある。ちょうど一致で判定すると
/// 「終わりで止まっている」と気付けず、再生を押しても頭出しされずにすぐ止まってしまう
/// （Android: PLAY_AT_END_TOLERANCE_MS）。
nonisolated let playAtEndToleranceMs: Int64 = 150

/// 再生を押したとき、どこから再生するか（Android: PlayFrom）
nonisolated enum PlayFrom: Equatable {
    /// いまの位置から（途中で止めていた、または次のクリップへ進める）
    case currentPosition

    /// タイムラインの先頭のクリップから（連続再生で最後のクリップの終わりで止まっていた）
    case timelineStart

    /// 選択中のクリップの頭から（連続再生オフで、クリップの終わりで止まっていた）
    case selectedClipStart
}

/// クリップの終わりで止まっているときに再生を押すと、そのまま再生してもトリミング終端の監視が
/// 直ちにまた止めてしまい、「再生できない」ように見える。終わりで止まっているときだけ頭出しする。
///
/// - 終わりで止まっていない → いまの位置から
/// - 連続再生オンで、最後のクリップではない → いまの位置から（次のクリップへ進む）
/// - 連続再生オンで、最後のクリップ → タイムラインの先頭から（最後で止めたあとの、再生のやり直し）
/// - 連続再生オフ → 選択中のクリップの頭から（1本ずつ見直す使い方）
///
/// Android版は引数に`playerEnded`（ExoPlayerがSTATE_ENDEDまで進んだか）も取るが、iOS版は
/// 終端で止めるときに必ず`trimEndMs`へ明示的にシークしているため、位置の比較だけで足りる。
nonisolated func playFromWhere(
    isLastClip: Bool,
    isContinuousPlay: Bool,
    positionMs: Int64,
    clipEndMs: Int64
) -> PlayFrom {
    let atEnd = positionMs >= clipEndMs - playAtEndToleranceMs
    switch (atEnd, isContinuousPlay, isLastClip) {
    case (false, _, _):       return .currentPosition
    case (true, true, false): return .currentPosition
    case (true, true, true):  return .timelineStart
    case (true, false, _):    return .selectedClipStart
    }
}
