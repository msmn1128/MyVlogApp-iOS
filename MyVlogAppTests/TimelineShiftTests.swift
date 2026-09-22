import Testing
@testable import MyVlogApp

/// 区間ごと移動でずらせる量（clampTimelineShift）。Android: VlogClipTest の clampTimelineShift
@Suite("区間ごと移動でずらせる量")
struct TimelineShiftTests {

    @Test("動かす区切りが無ければ、要求した量をそのまま返す")
    func noSplits() {
        let texts = TestClip.segments([(0, "A")])
        #expect(clampTimelineShift(texts: texts, requested: -5_000, durationMs: 10_000) == -5_000)
        #expect(clampTimelineShift(texts: texts, requested: 5_000, durationMs: 10_000) == 5_000)
    }

    @Test("範囲に収まる移動量はそのまま通る")
    func withinRange() {
        let texts = TestClip.segments([(0, "A"), (3_000, "B")])
        #expect(clampTimelineShift(texts: texts, requested: -1_000, durationMs: 10_000) == -1_000)
        #expect(clampTimelineShift(texts: texts, requested: 2_000, durationMs: 10_000) == 2_000)
    }

    @Test("左へ大きく動かしても、区切りが先頭へ潰れるところまでは詰められる")
    func clampsLeftInsteadOfCollapsing() {
        // 回帰テスト: 以前は区切りを1つずつ範囲へ丸めていたため、1000と5000が両方1msへ
        // 潰れて相対位置（4000msの間隔）が失われ、「もとに戻す」以外で復元できなかった
        let texts = TestClip.segments([(0, "A"), (1_000, "B"), (5_000, "C")])
        let delta = clampTimelineShift(texts: texts, requested: -6_000, durationMs: 10_000)

        // いちばん手前の区切り(1000)が下限(400)に届くところまで = -600 で止まる
        #expect(delta == -600)

        let moved = texts.map { $0.startMs == 0 ? $0.startMs : $0.startMs + delta }
        #expect(moved == [0, 400, 4_400])
        // 相対位置（区切り同士の間隔）が保たれている
        #expect(moved[2] - moved[1] == 4_000)
    }

    @Test("右へ大きく動かしても、いちばん後ろの区切りが尺を越えないところで止まる")
    func clampsRight() {
        let texts = TestClip.segments([(0, "A"), (1_000, "B"), (5_000, "C")])
        let delta = clampTimelineShift(texts: texts, requested: 9_000, durationMs: 10_000)
        #expect(delta == 5_000)   // 5000 + 5000 = 10000（尺ちょうど）
    }

    @Test("すでに範囲外の保存データでも、動かせなくはしない（許容範囲に0を含める）")
    func alreadyOutOfRange() {
        // 尺を越えた位置に区切りが残っている壊れたデータ。hi は max(...,0) で0になる
        let texts = TestClip.segments([(0, "A"), (12_000, "B")])
        #expect(clampTimelineShift(texts: texts, requested: 1_000, durationMs: 10_000) == 0)
        // 左へは動かせる（下限は 400 - 12000 = -11600）
        #expect(clampTimelineShift(texts: texts, requested: -1_000, durationMs: 10_000) == -1_000)
    }
}
