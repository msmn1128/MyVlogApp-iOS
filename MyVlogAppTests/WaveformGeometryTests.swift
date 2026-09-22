import CoreGraphics
import Testing
@testable import MyVlogApp

/// 波形のズーム範囲と px⇔ms 変換。Android: WaveformGeometryTest
@Suite("波形のズームと座標変換")
struct WaveformGeometryTests {

    // MARK: - fitViewport

    @Test("尺が0なら空のビューポート")
    func zeroDuration() {
        #expect(WaveformGeometry.fitViewport(startMs: 0, endMs: 0, durationMs: 0)
            == WaveformViewport(start: 0, end: 0))
    }

    @Test("大部分を選んでいるときはズームせず全体表示のまま")
    func wideSelectionStaysFull() {
        // しきい値は尺の60%。70%を選んでいるのでズームしない
        let viewport = WaveformGeometry.fitViewport(startMs: 0, endMs: 70_000, durationMs: 100_000)
        #expect(viewport == WaveformViewport(start: 0, end: 100_000))
    }

    @Test("一部だけを選んでいるときは選択範囲＋余白へズームする")
    func narrowSelectionZooms() {
        // 選択2秒 → 余白は選択の50%（=1000ms、下限300ms）を前後に
        let viewport = WaveformGeometry.fitViewport(startMs: 10_000, endMs: 12_000, durationMs: 100_000)
        #expect(viewport == WaveformViewport(start: 9_000, end: 13_000))
    }

    @Test("選択がごく短くても、表示幅の下限(3秒)は確保する")
    func keepsMinimumWindow() {
        let viewport = WaveformGeometry.fitViewport(startMs: 50_000, endMs: 50_200, durationMs: 100_000)
        #expect(viewport.end - viewport.start == 3_000)
    }

    @Test("動画の先頭に近いときは、前に伸ばせないぶんを後ろへ回して表示幅を保つ")
    func shiftsWindowAtStart() {
        let viewport = WaveformGeometry.fitViewport(startMs: 0, endMs: 500, durationMs: 100_000)
        #expect(viewport.start == 0)
        #expect(viewport.end == 3_000)
    }

    @Test("動画の終わりに近いときは、後ろに伸ばせないぶんを前へ回す")
    func shiftsWindowAtEnd() {
        let viewport = WaveformGeometry.fitViewport(startMs: 99_500, endMs: 100_000, durationMs: 100_000)
        #expect(viewport.end == 100_000)
        #expect(viewport.end - viewport.start == 3_000)
    }

    @Test("ビューポートは必ず 0…尺 の内側に収まる")
    func viewportStaysInsideDuration() {
        let viewport = WaveformGeometry.fitViewport(startMs: 200, endMs: 700, durationMs: 1_000)
        #expect(viewport.start >= 0)
        #expect(viewport.end <= 1_000)
    }

    // MARK: - px ⇔ ms

    private var geometry: WaveformGeometry {
        WaveformGeometry(left: 10, right: 110, viewport: WaveformViewport(start: 0, end: 1_000))
    }

    @Test("msToX と xToMs は往復する")
    func roundTrip() {
        #expect(geometry.msToX(0) == 10)
        #expect(geometry.msToX(1_000) == 110)
        #expect(geometry.msToX(500) == 60)
        #expect(geometry.xToMs(60, durationMs: 1_000) == 500)
    }

    @Test("xToMs は 0…尺 の外へは出さない")
    func xToMsClamps() {
        #expect(geometry.xToMs(-100, durationMs: 1_000) == 0)
        #expect(geometry.xToMs(500, durationMs: 1_000) == 1_000)
    }

    @Test("extrapolatedMs はクランプせず、端からのはみ出し量が分かる")
    func extrapolated() {
        // トリムつまみが表示端に達したときの自動パン量を決めるのに使う
        #expect(geometry.extrapolatedMs(110) == 1_000)
        #expect(geometry.extrapolatedMs(210) > 1_000)
        #expect(geometry.extrapolatedMs(-90) < 0)
    }

    @Test("幅が0でも0除算にならない")
    func degenerateWidth() {
        let narrow = WaveformGeometry.forWidth(10, handleW: 20, viewport: WaveformViewport(start: 0, end: 1_000))
        #expect(narrow.width >= 1)
        #expect(narrow.pxPerMs.isFinite)
    }
}
