import AVFoundation
import CoreGraphics
import Testing
@testable import MyVlogApp

// =====================================================================================
// 書き出した動画そのものを検証する結合テスト。
//
// これまで書き出しは「始まる・進捗が出る・中止できる」（ExportUITests）までしか
// 見ておらず、出来上がった動画の尺・解像度・焼き込んだ文字の位置は誰も確かめていなかった。
// ここでは ExportWorker を直接叩いて実際に1本書き出し、出力フレームのピクセルを見る。
//
// 焼き込み処理（ExportWorker+Drawing）の作り替えをするときは、まずこのテストが
// 通っていることを確かめてから着手すること。見た目の回帰をここで捕まえる。
//
// 実際にエンコードするので1件あたり数秒かかる。重い処理を同時に走らせて
// 取りこぼさないよう .serialized にしてある。
// =====================================================================================

@Suite("書き出した動画の中身", .serialized)
struct ExportOutputTests {

    private let canvas = VlogLayout.canvasSize

    /// 焼き込み位置の検査に使う領域（すべて左上原点、1920x1080のキャンバス座標）。
    ///
    /// 元動画は4:3なので、16:9のキャンバスへ収めると左右に黒帯ができる
    /// （320x240 → 1440x1080、x=240…1680）。撮影時刻はその右の黒帯に、
    /// ひとことは映像の上の中央に出る。`blank`はどちらにも当たらない対照用。
    private enum Region {
        /// ひとこと（上下左右中央）
        static let hitokoto  = CGRect(x: 800, y: 495, width: 320, height: 90)
        /// 撮影時刻（上下中央・右端から40pt内側）
        static let timestamp = CGRect(x: 1690, y: 495, width: 200, height: 90)
        /// 文字が出るはずのない左上（黒帯）
        static let blank     = CGRect(x: 0, y: 0, width: 200, height: 200)
        /// タイトルカードの「Vlog.」（中央から-70pt）
        static let titleLogo = CGRect(x: 700, y: 380, width: 520, height: 180)
        /// タイトルカードの日付（中央から+80pt）
        static let titleDate = CGRect(x: 700, y: 580, width: 520, height: 90)
    }

    private func makeClip(
        source: URL, startMs: Int64 = 0, endMs: Int64 = 1_000, text: String = "テスト"
    ) -> VlogClip {
        VlogClip(
            fileURL:    source,
            timeText:   "12:34",
            dateText:   "2026/09/22",
            durationMs: 1_000,
            width:      320,
            height:     240,
            texts:      [TextSegment(startMs: 0, text: text)],
            startMs:    startMs,
            endMs:      endMs
        )
    }

    // MARK: - クリップの書き出し

    @Test("クリップはキャンバス一杯（1920x1080）で書き出される")
    func clipIsRenderedAtCanvasSize() async throws {
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let output = try await ExportWorker().processClip(makeClip(source: source), silent: true)
        defer { TestVideoFactory.remove(source, output) }

        #expect(try await FrameInspector.displaySize(of: output) == canvas)
    }

    @Test("ひとことと撮影時刻が、期待した位置に焼き込まれている")
    func captionAndTimestampAreBurnedIn() async throws {
        // 回帰テスト: 焼き込みはフレームごとに自前でCGContextへ描いている（CoreAnimationToolを
        // 使わない方式）。描画の作り替えで位置がずれたり、文字が丸ごと消えたりしても
        // これまでは誰も気付けなかった
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let output = try await ExportWorker().processClip(makeClip(source: source), silent: true)
        defer { TestVideoFactory.remove(source, output) }

        let frame = try await FrameInspector.frame(of: output, atSeconds: 0.5)

        #expect(
            FrameInspector.brightPixelCount(frame, in: Region.hitokoto) > 0,
            "ひとことが中央に焼き込まれていない"
        )
        #expect(
            FrameInspector.brightPixelCount(frame, in: Region.timestamp) > 0,
            "撮影時刻が右端に焼き込まれていない"
        )
        #expect(
            FrameInspector.brightPixelCount(frame, in: Region.blank) == 0,
            "文字が出るはずのない左上に明るいピクセルがある（位置がずれている可能性）"
        )
    }

    @Test("トリムした区間の長さだけが書き出される")
    func onlyTrimmedRangeIsExported() async throws {
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let clip   = makeClip(source: source, startMs: 200, endMs: 800)   // 0.6秒
        let output = try await ExportWorker().processClip(clip, silent: true)
        defer { TestVideoFactory.remove(source, output) }

        let duration = try await FrameInspector.durationSeconds(of: output)
        #expect(abs(duration - 0.6) < 0.15, "トリム区間0.6秒に対して尺が \(duration) 秒")
    }

    @Test("無音指定のクリップには音声トラックを持たせない")
    func silentClipHasNoAudioTrack() async throws {
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let output = try await ExportWorker().processClip(makeClip(source: source), silent: true)
        defer { TestVideoFactory.remove(source, output) }

        #expect(try await FrameInspector.hasAudioTrack(output) == false)
    }

    // MARK: - タイトルカード

    @Test("タイトルカードは2秒・キャンバス一杯で、文言が中央に出る")
    func titleCardHasExpectedSizeAndText() async throws {
        let output = try await ExportWorker().createTitleCard(titleText: "2026/09/22")
        defer { TestVideoFactory.remove(output) }

        #expect(try await FrameInspector.displaySize(of: output) == canvas)
        let duration = try await FrameInspector.durationSeconds(of: output)
        #expect(
            abs(duration - VlogLayout.titleCardDuration) < 0.15,
            "タイトルカードの尺が \(duration) 秒"
        )

        let frame = try await FrameInspector.frame(of: output, atSeconds: 0.5)
        #expect(FrameInspector.brightPixelCount(frame, in: Region.titleLogo) > 0, "「Vlog.」が出ていない")
        #expect(FrameInspector.brightPixelCount(frame, in: Region.titleDate) > 0, "日付が出ていない")
    }

    @Test("タイトルカードは終わりまでにフェードアウトして真っ暗になる")
    func titleCardFadesOut() async throws {
        // フェードはAndroid版と数式レベルで合わせてある（frame 30から20フレームかけて0へ）。
        // 1.9秒（frame 57）は完全に消えているはず
        let output = try await ExportWorker().createTitleCard(titleText: "2026/09/22")
        defer { TestVideoFactory.remove(output) }

        let frame = try await FrameInspector.frame(of: output, atSeconds: 1.9)
        #expect(FrameInspector.brightPixelCount(frame, in: Region.titleLogo) == 0, "「Vlog.」が消えていない")
        #expect(FrameInspector.brightPixelCount(frame, in: Region.titleDate) == 0, "日付が消えていない")
    }

    // MARK: - 結合

    @Test("結合した動画の尺は、タイトルと各クリップの合計になる")
    func concatenatedDurationIsTheSum() async throws {
        let worker = ExportWorker()
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let title  = try await worker.createTitleCard(titleText: "2026/09/22")
        let clip   = try await worker.processClip(makeClip(source: source), silent: true)
        let merged = try await worker.concatenate(urls: [title, clip])
        defer { TestVideoFactory.remove(source, title, clip, merged) }

        let titleDuration  = try await FrameInspector.durationSeconds(of: title)
        let clipDuration   = try await FrameInspector.durationSeconds(of: clip)
        let mergedDuration = try await FrameInspector.durationSeconds(of: merged)

        #expect(
            abs(mergedDuration - (titleDuration + clipDuration)) < 0.15,
            "結合後 \(mergedDuration) 秒 ≠ \(titleDuration) + \(clipDuration) 秒"
        )
        #expect(try await FrameInspector.displaySize(of: merged) == canvas)
    }

    @Test("結合しても、クリップ側の焼き込み文字はそのまま残る")
    func concatenationKeepsBurnedInText() async throws {
        // 結合はパススルー（無劣化の再多重化）を狙うが、互換が無ければ再エンコードに落ちる。
        // どちらの経路でも文字が消えないことを確かめる
        let worker = ExportWorker()
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let title  = try await worker.createTitleCard(titleText: "2026/09/22")
        let clip   = try await worker.processClip(makeClip(source: source), silent: true)
        let merged = try await worker.concatenate(urls: [title, clip])
        defer { TestVideoFactory.remove(source, title, clip, merged) }

        // タイトル（2秒）のあと、クリップの途中にあたる時刻を見る
        let frame = try await FrameInspector.frame(of: merged, atSeconds: 2.5)
        #expect(FrameInspector.brightPixelCount(frame, in: Region.hitokoto) > 0, "結合後にひとことが消えている")
        #expect(FrameInspector.brightPixelCount(frame, in: Region.timestamp) > 0, "結合後に撮影時刻が消えている")
    }
}
