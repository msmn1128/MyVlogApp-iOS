import Testing
@testable import MyVlogApp

/// VlogClipの純粋な計算（尺・区間・分割点の判定）。Android: VlogClipTest
@Suite("VlogClip の区間計算")
struct VlogClipTests {

    @Test("トリム幅は end - start。逆転していても負にはならない")
    func trimmedDuration() {
        #expect(TestClip.make(durationMs: 10_000, startMs: 2_000, endMs: 8_000).trimmedDurationMs == 6_000)
        #expect(TestClip.make(durationMs: 10_000, startMs: 8_000, endMs: 2_000).trimmedDurationMs == 0)
    }

    @Test("区切り位置は2番目以降の区間の頭（先頭の0は含まない）")
    func splitPoints() {
        let clip = TestClip.make(texts: TestClip.segments([(0, "A"), (3_000, "B"), (6_000, "C")]))
        #expect(clip.splitPoints == [3_000, 6_000])
        #expect(TestClip.make().splitPoints.isEmpty)
    }

    @Test("その位置に出るひとことを返す")
    func textAtPosition() {
        let clip = TestClip.make(texts: TestClip.segments([(0, "A"), (3_000, "B"), (6_000, "C")]))
        #expect(clip.textIndexAt(positionMs: 0) == 0)
        #expect(clip.textIndexAt(positionMs: 2_999) == 0)
        #expect(clip.textIndexAt(positionMs: 3_000) == 1)
        #expect(clip.textAt(positionMs: 7_000) == "C")
    }

    @Test("区切りが1つも無ければ splitPointNear は nil")
    func splitPointNearWithoutSplits() {
        #expect(TestClip.make().splitPointNear(positionMs: 5_000) == nil)
    }

    @Test("許容範囲に複数の区切りが入るときは「最も近い方」を返す")
    func splitPointNearPicksClosest() {
        // 尺10秒なので許容幅は 10000/40 = 250ms
        let clip = TestClip.make(texts: TestClip.segments([(0, "A"), (3_000, "B"), (3_400, "C")]))
        // 3250 からは 3000 が250ms、3400 が150ms。後ろにある方が近いので 3400
        #expect(clip.splitPointNear(positionMs: 3_250) == 3_400)
        // 3150 からは 3000 が150ms、3400 が250ms。先にある方が近いので 3000
        #expect(clip.splitPointNear(positionMs: 3_150) == 3_000)
    }

    @Test("許容幅の外にある区切りは拾わない")
    func splitPointNearOutsideTolerance() {
        let clip = TestClip.make(texts: TestClip.segments([(0, "A"), (3_000, "B")]))
        #expect(clip.splitPointNear(positionMs: 3_300) == nil)
    }

    @Test("visibleTextSpans はトリム開始を0とした相対区間を返す")
    func visibleSpansAreRelative() {
        let clip = TestClip.make(
            durationMs: 10_000, startMs: 2_000, endMs: 8_000,
            texts: TestClip.segments([(0, "A"), (4_000, "B")])
        )
        let spans = clip.visibleTextSpans()
        #expect(spans.count == 2)
        #expect(spans[0].spanStart == 0 && spans[0].spanEnd == 2_000 && spans[0].text == "A")
        #expect(spans[1].spanStart == 2_000 && spans[1].spanEnd == 6_000 && spans[1].text == "B")
    }

    @Test("トリムで落とした手前の区間は消えるが、トリム開始時点で出ている文字は残る")
    func visibleSpansDropLeadingSegments() {
        let clip = TestClip.make(
            durationMs: 10_000, startMs: 6_000, endMs: 9_000,
            texts: TestClip.segments([(0, "A"), (1_000, "B"), (5_000, "C")])
        )
        let spans = clip.visibleTextSpans()
        #expect(spans.count == 1)
        #expect(spans[0].text == "C")
        #expect(spans[0].spanStart == 0 && spans[0].spanEnd == 3_000)
    }

    @Test("isValid は尺0・範囲の逆転を弾く")
    func isValid() {
        #expect(TestClip.make(durationMs: 10_000, startMs: 0, endMs: 10_000).isValid)
        #expect(!TestClip.make(durationMs: 0, startMs: 0, endMs: 0).isValid)
        #expect(!TestClip.make(durationMs: 10_000, startMs: 5_000, endMs: 5_000).isValid)
    }

    @Test("sortKeyMs は shotAtMillis を優先し、無ければ表示文字列から逆算する")
    func sortKey() {
        #expect(TestClip.make(shotAtMillis: 1_234).sortKeyMs == 1_234)
        // shotAtMillisが無い旧データは dateText/timeText から復元できる
        let legacy = TestClip.make(shotAtMillis: 0, timeText: "10:00", dateText: "2026/09/20")
        #expect(legacy.sortKeyMs != .max)
        // 書式が壊れていれば最後尾へ送る
        let broken = TestClip.make(shotAtMillis: 0, timeText: "??", dateText: "??")
        #expect(broken.sortKeyMs == .max)
    }

    @Test("trimBounds はトリムだけを見る（ひとことの変更では変わらない）")
    func trimBoundsIgnoresTexts() {
        // ContentViewはこの値のonChangeでプレイヤーの終端監視を張り直す。
        // ひとことを1文字打つたびに発火しないことが、ここに切り出した理由そのもの
        let base = TestClip.make(durationMs: 10_000, startMs: 1_000, endMs: 8_000)
        var edited = base
        edited.texts = TestClip.segments([(0, "A"), (3_000, "B")])
        #expect(edited.trimBounds == base.trimBounds)

        var trimmed = base
        trimmed.endMs = 3_000
        #expect(trimmed.trimBounds != base.trimBounds)
        #expect(trimmed.trimBounds == TrimBounds(startMs: 1_000, endMs: 3_000))
    }

    @Test("mediaCacheKey は同じ素材なら一致し、別素材なら異なる")
    func mediaCacheKey() {
        var a = TestClip.make(); a.assetIdentifier = "PH-1"
        var b = TestClip.make(); b.assetIdentifier = "PH-1"
        var c = TestClip.make(); c.assetIdentifier = "PH-2"
        // 同じ動画を2回追加してもデコードをやり直さないための前提
        #expect(a.mediaCacheKey == b.mediaCacheKey)
        #expect(a.mediaCacheKey != c.mediaCacheKey)
    }
}
