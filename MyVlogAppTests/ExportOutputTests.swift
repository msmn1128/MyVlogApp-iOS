import AVFoundation
import CoreGraphics
import UIKit
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

/// ExportWorkerを、アプリが実際に走らせるのと同じ優先度（utility）で呼ぶための薄い包み。
///
/// テストからそのままawaitすると優先度が引き上げられて本番と条件が変わってしまう
/// （詳しくは TestVideoFactory.swift の `runAtExportPriority`）。
private nonisolated struct ExportRunner {
    private let worker = ExportWorker()

    func processClip(_ clip: VlogClip, silent: Bool) async throws -> URL {
        let worker = self.worker
        return try await runAtExportPriority { try await worker.processClip(clip, silent: silent) }
    }

    func createTitleCard(titleText: String) async throws -> URL {
        let worker = self.worker
        return try await runAtExportPriority { try await worker.createTitleCard(titleText: titleText) }
    }

    func addTitleSfx(to url: URL) async throws -> URL {
        let worker = self.worker
        return try await runAtExportPriority { try await worker.addTitleSfx(to: url) }
    }

    func concatenate(urls: [URL]) async throws -> URL {
        let worker = self.worker
        return try await runAtExportPriority { try await worker.concatenate(urls: urls) }
    }
}

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
        let output = try await ExportRunner().processClip(makeClip(source: source), silent: true)
        defer { TestVideoFactory.remove(source, output) }

        #expect(try await FrameInspector.displaySize(of: output) == canvas)
    }

    @Test("ひとことと撮影時刻が、期待した位置に焼き込まれている")
    func captionAndTimestampAreBurnedIn() async throws {
        // 回帰テスト: 焼き込みはフレームごとに自前でCGContextへ描いている（CoreAnimationToolを
        // 使わない方式）。描画の作り替えで位置がずれたり、文字が丸ごと消えたりしても
        // これまでは誰も気付けなかった
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let output = try await ExportRunner().processClip(makeClip(source: source), silent: true)
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

    @Test("ひとことの絵文字は、書き出した動画にもカラーで出る")
    func emojiIsBurnedInColor() async throws {
        // Android版では書き出しから絵文字が消えていた（drawtext）。iOS版はプレビューと同じ描画関数
        // （CaptionRenderer）で描くので、端末の絵文字フォントでカラーのまま焼き込まれる
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let output = try await ExportRunner().processClip(makeClip(source: source, text: "😀"), silent: true)
        defer { TestVideoFactory.remove(source, output) }

        let frame = try await FrameInspector.frame(of: output, atSeconds: 0.5)
        // 😀の黄色（赤・緑が強く青が弱い）。元の動画は暗い灰色なので、黄色い画素は絵文字しかない
        let yellow = FrameInspector.pixelCount(frame, in: Region.hitokoto) { r, g, b in r > 180 && g > 140 && b < 90 }
        #expect(yellow > 200, "絵文字がカラーで出ていない（黄色い画素 \(yellow)）")
    }

    @Test("トリムした区間の長さだけが書き出される")
    func onlyTrimmedRangeIsExported() async throws {
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let clip   = makeClip(source: source, startMs: 200, endMs: 800)   // 0.6秒
        let output = try await ExportRunner().processClip(clip, silent: true)
        defer { TestVideoFactory.remove(source, output) }

        let duration = try await FrameInspector.durationSeconds(of: output)
        #expect(abs(duration - 0.6) < 0.15, "トリム区間0.6秒に対して尺が \(duration) 秒")
    }

    @Test("無音指定のクリップには音声トラックを持たせない")
    func silentClipHasNoAudioTrack() async throws {
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let output = try await ExportRunner().processClip(makeClip(source: source), silent: true)
        defer { TestVideoFactory.remove(source, output) }

        #expect(try await FrameInspector.hasAudioTrack(output) == false)
    }

    // MARK: - 色（HDR → SDR）

    /// 書き出した動画の1コマ（ひとことの位置）の色と、元の動画をシステムが表示したときの色を比べる。
    /// ひとことは空にして、映像そのものの色だけを見る
    private func colorsAfterExport(of source: URL) async throws -> (output: (r: Double, g: Double, b: Double), source: (r: Double, g: Double, b: Double)) {
        let output = try await ExportRunner().processClip(makeClip(source: source, text: ""), silent: true)
        defer { TestVideoFactory.remove(output) }
        let exported = try await FrameInspector.frame(of: output, atSeconds: 0.5)
        let original = try await FrameInspector.frame(of: source, atSeconds: 0.5)
        return (
            FrameInspector.meanRGB(exported, in: Region.hitokoto),
            FrameInspector.meanRGB(original, in: CGRect(x: 100, y: 100, width: 50, height: 50))
        )
    }

    private func isClose(
        _ a: (r: Double, g: Double, b: Double), _ b: (r: Double, g: Double, b: Double), within tolerance: Double
    ) -> Bool {
        abs(a.r - b.r) <= tolerance && abs(a.g - b.g) <= tolerance && abs(a.b - b.b) <= tolerance
    }

    @Test("SDRの動画は、元の色のまま書き出される")
    func sdrColorsArePreserved() async throws {
        // 回帰テスト: 合成と出力の色空間を決めていなかった頃は、変換式の食い違いで
        // 元の(73,149,88)が(65,151,87)のようにずれていた
        let source = try await TestVideoFactory.makeSolidColorVideo(
            seconds: 1, color: UIColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1)
        )
        defer { TestVideoFactory.remove(source) }

        let colors = try await colorsAfterExport(of: source)
        #expect(isClose(colors.output, colors.source, within: 6), "出力 \(colors.output) / 元 \(colors.source)")
    }

    @Test("HLG（HDR）の動画は、SDRへ変換して書き出される")
    func hlgIsConvertedToSdr() async throws {
        // 回帰テスト: 以前はHLGの値をほぼSDRのまま扱い、システムが表示する色(0,107,53)に対して
        // (62,143,86)と白っぽく色が抜けていた（Android: Hdr.kt と同じ問題）
        let source = try await TestVideoFactory.makeSolidColorVideo(
            seconds: 1, color: UIColor(red: 0.2, green: 0.5, blue: 0.3, alpha: 1),
            colorProperties: TestVideoFactory.hlgColorProperties
        )
        defer { TestVideoFactory.remove(source) }

        let colors = try await colorsAfterExport(of: source)
        #expect(isClose(colors.output, colors.source, within: 14), "出力 \(colors.output) / 元 \(colors.source)")
    }

    @Test("書き出した動画にはBT.709の色空間の情報が付いている")
    func outputIsTaggedAsRec709() async throws {
        // 付けないと再生する側が変換式を推測し、BT.601と取られると色がずれる（Android: videoEncodeArgs）
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let output = try await ExportRunner().processClip(makeClip(source: source), silent: true)
        defer { TestVideoFactory.remove(source, output) }

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
                == kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
        #expect(extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
                == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
    }

    /// 音声の長さが映像と違う動画を書き出して2本つないだときの、各トラックの長さ
    private func mergedTracks(videoSeconds: Double, audioSeconds: Double) async throws -> (clip: (video: Double, audio: Double?), merged: (video: Double, audio: Double?)) {
        let source = try await TestVideoFactory.makeVideoWithAudio(videoSeconds: videoSeconds, audioSeconds: audioSeconds)
        // 取り込み時の尺は動画全体の長さ（映像と音声の長い方）になる
        let durationMs = Int64(try await AVURLAsset(url: source).load(.duration).seconds * 1000)
        var clip = makeClip(source: source, endMs: durationMs)
        clip.durationMs = durationMs
        let first  = try await ExportRunner().processClip(clip, silent: false)
        let second = try await ExportRunner().processClip(clip, silent: false)
        let merged = try await ExportRunner().concatenate(urls: [first, second])
        defer { TestVideoFactory.remove(source, first, second, merged) }
        return (try await TestVideoFactory.trackSeconds(of: first), try await TestVideoFactory.trackSeconds(of: merged))
    }

    @Test("音声が映像より長い動画をつないでも、映像に隙間ができない")
    func longerAudioIsCutToTheVideo() async throws {
        // 回帰テスト: 映像1.0秒・音声1.3秒の動画を2本つなぐと、2本目の映像が1.3秒から始まり、
        // 映像に0.3秒の隙間ができていた（Android: 音声を apad → atrim で映像と同じ尺に強制する）
        let tracks = try await mergedTracks(videoSeconds: 1, audioSeconds: 1.3)
        #expect(abs((tracks.clip.audio ?? 0) - tracks.clip.video) < 0.05, "クリップの音声が映像より長い: \(tracks.clip)")
        #expect(abs(tracks.merged.video - 2.0) < 0.05, "つないだ映像の長さ: \(tracks.merged)")
        #expect(abs((tracks.merged.audio ?? 0) - 2.0) < 0.05, "つないだ音声の長さ: \(tracks.merged)")
    }

    @Test("音声が映像より短い動画をつないでも、2本目の音声は2本目の映像の頭から始まる")
    func shorterAudioStaysInPlace() async throws {
        let tracks = try await mergedTracks(videoSeconds: 1, audioSeconds: 0.6)
        #expect(abs(tracks.merged.video - 2.0) < 0.05, "つないだ映像の長さ: \(tracks.merged)")
        // 2本目の音声は1.0〜1.6秒。末尾がずれていなければ、頭もずれていない
        #expect(abs((tracks.merged.audio ?? 0) - 1.6) < 0.05, "つないだ音声の長さ: \(tracks.merged)")
    }

    /// 動画の音声トラックに入っている形式の数と、そのサンプリング周波数
    private func audioFormats(of url: URL) async throws -> [Double] {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first else { return [] }
        return try await track.load(.formatDescriptions).compactMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate
        }
    }

    @Test("音声の形式が違うクリップをつないでも、書き出した動画の音声は1つの形式にそろう")
    func mixedAudioFormatsAreUnified() async throws {
        // 回帰テスト: 結合で音声を変換せずにつないでいたため、44.1kHzと48kHzのクリップを混ぜると
        // 1本の音声トラックに形式が2つ混ざっていた。再生するアプリや変換によっては音が途切れる・
        // 音程がずれる（Android版は最後に音声だけを1回AACへ変換している）
        let a = try await TestVideoFactory.makeVideoWithAudio(videoSeconds: 1, audioSeconds: 1, sampleRate: 44_100)
        let b = try await TestVideoFactory.makeVideoWithAudio(videoSeconds: 1, audioSeconds: 1, sampleRate: 48_000)
        var clipA = makeClip(source: a); clipA.durationMs = 1_000
        var clipB = makeClip(source: b); clipB.durationMs = 1_000
        let outA = try await ExportRunner().processClip(clipA, silent: false)
        let outB = try await ExportRunner().processClip(clipB, silent: false)
        let merged = try await ExportRunner().concatenate(urls: [outA, outB])
        defer { TestVideoFactory.remove(a, b, outA, outB, merged) }

        #expect(try await audioFormats(of: merged) == [48_000], "音声の形式が1つにそろっていない")
        let tracks = try await TestVideoFactory.trackSeconds(of: merged)
        #expect(abs(tracks.video - 2.0) < 0.05, "映像の長さ: \(tracks)")
        // 映像はそのまま書くので、色空間の情報（BT.709）も残っていること
        let video = try #require(try await AVURLAsset(url: merged).loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
                == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
    }

    @Test("結合の途中で中止しても止まり、中止として戻る", .timeLimit(.minutes(1)))
    func cancellingTheMergeReturnsPromptly() async throws {
        // 結合は映像と音声を別々の流し手で書く。中止したときに片方が「書き手が受け取れるようになる」の
        // 知らせを待ったまま戻らないと、書き出しの画面が消えず、次の書き出しも始められなくなる
        let voiced = try await TestVideoFactory.makeVideoWithAudio(videoSeconds: 2, audioSeconds: 2, sampleRate: 48_000)
        var clip = makeClip(source: voiced, endMs: 2_000); clip.durationMs = 2_000
        let out = try await ExportRunner().processClip(clip, silent: false)
        defer { TestVideoFactory.remove(voiced, out) }

        // 止まるまでの時間は端末の速さで変わるので、中止する時点をずらして何回か試す。
        // どの回も（時間の上限までに）戻ること、中止が間に合った回は中止として戻ることを確かめる
        let urls = Array(repeating: out, count: 60)
        var cancelledRuns = 0
        for delayMs in [0, 20, 50, 100, 200, 400] as [UInt64] {
            let task = Task { try await ExportRunner().concatenate(urls: urls) }
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            task.cancel()
            switch await task.result {
            case .success(let merged):
                TestVideoFactory.remove(merged)
            case .failure(let error):
                #expect(error is CancellationError, "\(delayMs)msで中止したら、中止ではなく失敗として戻った: \(error)")
                cancelledRuns += 1
            }
        }
        #expect(cancelledRuns > 0, "どの回も中止が間に合わなかった（確かめられていない）")
    }

    @Test("音声の無いクリップのあとのクリップの音は、そのクリップの映像の頭から鳴る")
    func audioStaysAlignedAfterASilentClip() async throws {
        // 1本目は音声なし（1秒）、2本目は頭から鳴る。つないだ動画では、ちょうど1秒の位置から鳴ること。
        // 音声だけを変換し直すときに、無音の区間を詰めたり、変換の遅れ（AACの頭の無音）ぶんずれたり
        // していないかを確かめる（Android: 区切りのつなぎ目で音と映像がずれないことの確認）
        let silent = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let voiced = try await TestVideoFactory.makeVideoWithAudio(videoSeconds: 1, audioSeconds: 1, sampleRate: 48_000)
        var clipA = makeClip(source: silent); clipA.durationMs = 1_000
        var clipB = makeClip(source: voiced); clipB.durationMs = 1_000
        let outA = try await ExportRunner().processClip(clipA, silent: false)
        let outB = try await ExportRunner().processClip(clipB, silent: false)
        let merged = try await ExportRunner().concatenate(urls: [outA, outB])
        defer { TestVideoFactory.remove(silent, voiced, outA, outB, merged) }

        let onset = try #require(try await TestVideoFactory.audioOnsetSeconds(of: merged), "音が鳴っていない")
        #expect(abs(onset - 1.0) <= 0.06, "2本目の音が \(onset) 秒から鳴った（1.0秒のはず）")
    }

    // MARK: - タイトルカード

    @Test("タイトルカードは2秒・キャンバス一杯で、文言が中央に出る")
    func titleCardHasExpectedSizeAndText() async throws {
        let output = try await ExportRunner().createTitleCard(titleText: "2026/09/22")
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
        let output = try await ExportRunner().createTitleCard(titleText: "2026/09/22")
        defer { TestVideoFactory.remove(output) }

        let frame = try await FrameInspector.frame(of: output, atSeconds: 1.9)
        #expect(FrameInspector.brightPixelCount(frame, in: Region.titleLogo) == 0, "「Vlog.」が消えていない")
        #expect(FrameInspector.brightPixelCount(frame, in: Region.titleDate) == 0, "日付が消えていない")
    }

    // MARK: - 結合

    @Test("結合した動画の尺は、タイトルと各クリップの合計になる")
    func concatenatedDurationIsTheSum() async throws {
        let runner = ExportRunner()
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let title  = try await runner.createTitleCard(titleText: "2026/09/22")
        let clip   = try await runner.processClip(makeClip(source: source), silent: true)
        let merged = try await runner.concatenate(urls: [title, clip])
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
        let runner = ExportRunner()
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let title  = try await runner.createTitleCard(titleText: "2026/09/22")
        let clip   = try await runner.processClip(makeClip(source: source), silent: true)
        let merged = try await runner.concatenate(urls: [title, clip])
        defer { TestVideoFactory.remove(source, title, clip, merged) }

        // タイトル（2秒）のあと、クリップの途中にあたる時刻を見る
        let frame = try await FrameInspector.frame(of: merged, atSeconds: 2.5)
        #expect(FrameInspector.brightPixelCount(frame, in: Region.hitokoto) > 0, "結合後にひとことが消えている")
        #expect(FrameInspector.brightPixelCount(frame, in: Region.timestamp) > 0, "結合後に撮影時刻が消えている")
    }

    @Test("効果音付きのタイトル（書き出しの既定）とつないでも、タイトル・クリップの映像と効果音がそろう")
    func concatenationWithTitleSfxKeepsPictureAndSound() async throws {
        // 書き出しの既定（ミュートしていない）では、タイトルは効果音を足すときに作り直される。
        // その形のタイトルとつないだときに、映像がどちらも正しく読め、効果音の位置もずれないこと
        let runner = ExportRunner()
        let source = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        let title  = try await runner.createTitleCard(titleText: "2026/09/22")
        let titled = try await runner.addTitleSfx(to: title)
        let clip   = try await runner.processClip(makeClip(source: source), silent: true)
        let merged = try await runner.concatenate(urls: [titled, clip])
        defer { TestVideoFactory.remove(source, title, titled, clip, merged) }

        #expect(titled != title, "効果音を足せていない")
        let duration = try await FrameInspector.durationSeconds(of: merged)
        #expect(abs(duration - 3.0) < 0.15, "結合後 \(duration) 秒（3秒のはず）")
        let titleFrame = try await FrameInspector.frame(of: merged, atSeconds: 0.5)
        #expect(FrameInspector.brightPixelCount(titleFrame, in: Region.titleLogo) > 0, "タイトルの「Vlog.」が見えない")
        let clipFrame = try await FrameInspector.frame(of: merged, atSeconds: 2.5)
        #expect(FrameInspector.brightPixelCount(clipFrame, in: Region.hitokoto) > 0, "タイトルのあとのクリップのひとことが見えない")
        let onset = try #require(try await TestVideoFactory.audioOnsetSeconds(of: merged), "効果音が鳴っていない")
        let expected = Double(VlogLayout.titleSfxFrameNumber - 1) / 30.0
        #expect(abs(onset - expected) <= 0.08, "効果音が \(onset) 秒から鳴った（\(expected) 秒のはず）")
    }
}
