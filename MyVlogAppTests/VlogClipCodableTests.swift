import Foundation
import Testing
@testable import MyVlogApp

/// 保存データの読み書きと、壊れた／古いデータの正規化。Android: VlogClipJsonTest
@Suite("VlogClip の保存データ")
struct VlogClipCodableTests {

    /// 保存JSONを手で組み立てて読み込む。実際の保存データ（UserDefaults内のJSON）と
    /// 同じ経路（JSONDecoder）を通したいので、VlogClipを作ってからencodeするのではなく
    /// 辞書から起こす
    private func decode(_ json: [String: Any]) throws -> VlogClip {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(VlogClip.self, from: data)
    }

    private func baseJSON(
        durationMs: Int = 10_000,
        startMs: Int = 0,
        endMs: Int = 10_000,
        texts: [[String: Any]] = [["startMs": 0, "text": "A"]]
    ) -> [String: Any] {
        [
            "timeText": "10:00", "dateText": "2026/09/20",
            "durationMs": durationMs, "width": 1920, "height": 1080,
            "texts": texts, "startMs": startMs, "endMs": endMs
        ]
    }

    // MARK: - トリム位置の正規化

    @Test("end < start の壊れたデータは end を start まで引き上げる")
    func normalizesReversedTrim() throws {
        let clip = try decode(baseJSON(startMs: 8_000, endMs: 2_000))
        #expect(clip.startMs == 8_000)
        #expect(clip.endMs == 8_000)
        #expect(clip.trimmedDurationMs == 0)
    }

    @Test("尺を越えるトリム位置は尺へ丸める")
    func clampsTrimToDuration() throws {
        let clip = try decode(baseJSON(durationMs: 5_000, startMs: 9_000, endMs: 20_000))
        #expect(clip.startMs == 5_000)
        #expect(clip.endMs == 5_000)
    }

    @Test("負のトリム位置は0へ丸める")
    func clampsNegativeTrim() throws {
        let clip = try decode(baseJSON(startMs: -3_000, endMs: 4_000))
        #expect(clip.startMs == 0)
        #expect(clip.endMs == 4_000)
    }

    @Test("負の尺は0にする")
    func clampsNegativeDuration() throws {
        let clip = try decode(baseJSON(durationMs: -1, startMs: 0, endMs: 0))
        #expect(clip.durationMs == 0)
    }

    // MARK: - ひとことの正規化

    @Test("並びが崩れていても昇順へ直し、文言は全部残す")
    func sortsSegments() throws {
        let clip = try decode(baseJSON(texts: [
            ["startMs": 6_000, "text": "C"],
            ["startMs": 0, "text": "A"],
            ["startMs": 3_000, "text": "B"]
        ]))
        #expect(clip.texts.map(\.startMs) == [0, 3_000, 6_000])
        #expect(clip.texts.map(\.text) == ["A", "B", "C"])
    }

    @Test("先頭が0で始まっていなければ、位置だけ0へ直して文言は残す")
    func fixesFirstSegmentStart() throws {
        let clip = try decode(baseJSON(texts: [
            ["startMs": 1_500, "text": "A"],
            ["startMs": 4_000, "text": "B"]
        ]))
        #expect(clip.texts.count == 2)
        #expect(clip.texts[0].startMs == 0)
        #expect(clip.texts[0].text == "A")   // 文言は巻き添えにしない
        #expect(clip.texts[1].startMs == 4_000)
    }

    @Test("負の位置が2件以上あっても、0へ丸めてから並べるので昇順が崩れない")
    func clampsNegativeSegmentPositions() throws {
        let clip = try decode(baseJSON(texts: [
            ["startMs": -5, "text": "A"],
            ["startMs": -3, "text": "B"],
            ["startMs": 1_000, "text": "C"]
        ]))
        #expect(clip.texts.map(\.startMs) == [0, 0, 1_000])
        #expect(clip.texts.map(\.text) == ["A", "B", "C"])
    }

    @Test("区間が空なら既定の1件を入れる（0件だと書き出しから文字が消える）")
    func emptySegmentsBecomeDefault() throws {
        let clip = try decode(baseJSON(texts: []))
        #expect(clip.texts.count == 1)
        #expect(clip.texts[0].startMs == 0)
        #expect(clip.texts[0].text == "")
    }

    @Test("正規化後は textAt がどの位置でも文字を拾える")
    func normalizedSegmentsAlwaysResolve() throws {
        let clip = try decode(baseJSON(texts: [
            ["startMs": 9_000, "text": "後"],
            ["startMs": 2_000, "text": "先"]
        ]))
        #expect(clip.textAt(positionMs: 0) == "先")
        #expect(clip.textAt(positionMs: 9_500) == "後")
    }

    // MARK: - 旧データとの互換

    @Test("撮影時刻の確かさを持たせる前の保存データは「確かでない」扱いで読む")
    func oldDataIsUnreliable() throws {
        let clip = try decode(baseJSON())
        // キーが無い＝取り込み時刻で代用した値が混ざっている可能性があるので、
        // 次回の復元時に一度だけ取り直させる
        #expect(clip.shotAtReliable == false)
        #expect(clip.shotAtRefreshed == false)
    }

    @Test("ミュート・撮影時刻のキーが無くても読める")
    func missingOptionalKeys() throws {
        let clip = try decode(baseJSON())
        #expect(clip.isMuted == false)
        #expect(clip.shotAtMillis == 0)
    }

    // MARK: - 往復

    @Test("エンコードしてデコードすると同じ内容に戻る")
    func roundTrip() throws {
        var original = TestClip.make(
            durationMs: 12_000, startMs: 1_000, endMs: 9_000,
            texts: TestClip.segments([(0, "A"), (4_000, "B")]),
            shotAtMillis: 1_700_000_000_000
        )
        original.assetIdentifier = "PH-1"
        original.isMuted = true
        original.shotAtReliable = true
        original.shotAtRefreshed = true

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VlogClip.self, from: data)

        #expect(decoded == original)
        #expect(decoded.shotAtReliable)
        #expect(decoded.shotAtRefreshed)
    }
}
