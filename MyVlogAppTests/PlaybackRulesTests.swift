import Testing
@testable import MyVlogApp

/// 再生ボタンを押したときの頭出し判断。Android: PlaybackSpecTest
@Suite("再生ボタンの頭出し判断")
struct PlaybackRulesTests {

    @Test("途中で止めていたなら、いまの位置から続ける")
    func middleOfClip() {
        #expect(playFromWhere(
            isLastClip: false, isContinuousPlay: true, positionMs: 3_000, clipEndMs: 10_000
        ) == .currentPosition)
        #expect(playFromWhere(
            isLastClip: true, isContinuousPlay: false, positionMs: 3_000, clipEndMs: 10_000
        ) == .currentPosition)
    }

    @Test("連続再生オンで最後のクリップでなければ、終端でもそのまま次へ進む")
    func atEndWithMoreClips() {
        #expect(playFromWhere(
            isLastClip: false, isContinuousPlay: true, positionMs: 10_000, clipEndMs: 10_000
        ) == .currentPosition)
    }

    @Test("連続再生オンで最後のクリップの終端なら、タイムラインの先頭からやり直す")
    func atEndOfTimeline() {
        #expect(playFromWhere(
            isLastClip: true, isContinuousPlay: true, positionMs: 10_000, clipEndMs: 10_000
        ) == .timelineStart)
    }

    @Test("連続再生オフで終端なら、選択中のクリップの頭から")
    func atEndWithoutContinuousPlay() {
        #expect(playFromWhere(
            isLastClip: false, isContinuousPlay: false, positionMs: 10_000, clipEndMs: 10_000
        ) == .selectedClipStart)
        #expect(playFromWhere(
            isLastClip: true, isContinuousPlay: false, positionMs: 10_000, clipEndMs: 10_000
        ) == .selectedClipStart)
    }

    @Test("終端のわずか手前で止まっていても「終端」とみなす")
    func toleranceCountsAsEnd() {
        // 止めた位置はendMs（メタデータ由来）ちょうどにならないことがある。
        // ちょうど一致で見ていると頭出しが効かず、再生を押しても即座に止まって見える
        let justInside = 10_000 - playAtEndToleranceMs + 1
        #expect(playFromWhere(
            isLastClip: false, isContinuousPlay: false, positionMs: justInside, clipEndMs: 10_000
        ) == .selectedClipStart)
    }

    @Test("許容幅より手前なら終端扱いしない")
    func outsideToleranceIsNotEnd() {
        let outside = 10_000 - playAtEndToleranceMs - 1
        #expect(playFromWhere(
            isLastClip: false, isContinuousPlay: false, positionMs: outside, clipEndMs: 10_000
        ) == .currentPosition)
    }
}
