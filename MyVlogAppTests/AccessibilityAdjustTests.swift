import Testing
@testable import MyVlogApp

/// VoiceOverの「調整」（上下スワイプ）でトリムを動かすときの計算。
///
/// 波形はCanvas描画で、つまみはドラッグでしか動かせなかった＝支援技術からは
/// トリムを一切変更できなかった。調整操作を足すにあたって、ドラッグと同じ制約が
/// 効いていることをここで守る（画面の側はWaveformViewが呼ぶだけ）。
@Suite("VoiceOverの調整でのトリム")
struct AccessibilityAdjustTests {

    // MARK: - 1回あたりの移動量

    @Test("移動量は尺の50分の1を基準にする")
    func stepScalesWithDuration() {
        #expect(accessibilityAdjustStepMs(durationMs: 10_000) == 200)
        #expect(accessibilityAdjustStepMs(durationMs: 25_000) == 500)
    }

    @Test("短い動画でも粗すぎず、長い動画でも細かすぎない範囲に収める")
    func stepIsClamped() {
        // 短い動画: 50分の1では細かすぎて目的の位置まで遠いので下限0.1秒
        #expect(accessibilityAdjustStepMs(durationMs: 1_000) == 100)
        // 長い動画: 50分の1では粗すぎて合わせられないので上限1秒
        #expect(accessibilityAdjustStepMs(durationMs: 600_000) == 1_000)
        // 尺が0や負の壊れたデータでも0にはしない（動かせなくなってしまう）
        #expect(accessibilityAdjustStepMs(durationMs: 0) == 100)
        #expect(accessibilityAdjustStepMs(durationMs: -1) == 100)
    }

    // MARK: - トリム開始

    @Test("トリム開始は前後に動く")
    func trimStartMoves() {
        let clip = TestClip.make(durationMs: 10_000, startMs: 2_000, endMs: 8_000)
        #expect(adjustedTrimStartMs(clip: clip, deltaMs: 500) == 2_500)
        #expect(adjustedTrimStartMs(clip: clip, deltaMs: -500) == 1_500)
    }

    @Test("トリム開始は動画の頭より手前へは行かない")
    func trimStartStopsAtZero() {
        let clip = TestClip.make(durationMs: 10_000, startMs: 300, endMs: 8_000)
        #expect(adjustedTrimStartMs(clip: clip, deltaMs: -1_000) == 0)
    }

    @Test("トリム開始は、終了との間隔が最短トリムを割るところで止まる")
    func trimStartKeepsMinimumSpan() {
        // ドラッグ（clampTrimHandleMs）と同じ制約。ここが抜けると長さ0のクリップを作れてしまう
        let clip = TestClip.make(durationMs: 10_000, startMs: 2_000, endMs: 5_000)
        let limit = 5_000 - VlogClip.minTrimMs
        #expect(adjustedTrimStartMs(clip: clip, deltaMs: 9_000) == limit)
    }

    // MARK: - トリム終了

    @Test("トリム終了は前後に動く")
    func trimEndMoves() {
        let clip = TestClip.make(durationMs: 10_000, startMs: 2_000, endMs: 8_000)
        #expect(adjustedTrimEndMs(clip: clip, deltaMs: 500) == 8_500)
        #expect(adjustedTrimEndMs(clip: clip, deltaMs: -500) == 7_500)
    }

    @Test("トリム終了は動画の終わりより後ろへは行かない")
    func trimEndStopsAtDuration() {
        let clip = TestClip.make(durationMs: 10_000, startMs: 2_000, endMs: 9_800)
        #expect(adjustedTrimEndMs(clip: clip, deltaMs: 1_000) == 10_000)
    }

    @Test("トリム終了は、開始との間隔が最短トリムを割るところで止まる")
    func trimEndKeepsMinimumSpan() {
        let clip = TestClip.make(durationMs: 10_000, startMs: 5_000, endMs: 8_000)
        let limit = 5_000 + VlogClip.minTrimMs
        #expect(adjustedTrimEndMs(clip: clip, deltaMs: -9_000) == limit)
    }

    @Test("端まで動かしきっても、範囲が逆転したり0にはならない")
    func spanNeverCollapses() {
        let clip = TestClip.make(durationMs: 10_000, startMs: 2_000, endMs: 8_000)
        let start = adjustedTrimStartMs(clip: clip, deltaMs: 99_999)
        let end   = adjustedTrimEndMs(clip: clip, deltaMs: -99_999)
        #expect(start < clip.endMs)
        #expect(end > clip.startMs)
        #expect(clip.endMs - start >= VlogClip.minTrimMs)
        #expect(end - clip.startMs >= VlogClip.minTrimMs)
    }
}
