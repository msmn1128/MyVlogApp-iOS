import AVFoundation
import UIKit
import Photos

/// 書き出しパイプラインの重い処理（AVFoundationの読み書き・CGContextへのフレームごとの
/// テキスト焼き込み）だけを担当するactor。
///
/// ExportManager本体は@MainActorで、@Publishedなprogress/messageの更新を安全に行う
/// ためにそう指定してある。以前はここに置かれている処理も丸ごと同じ@MainActor上
/// （＝メインスレッド）で動いていたため、シミュレータの短いテストクリップでは
/// 気づかないが、実機で長め・高解像度の本物の動画を書き出すとメインスレッドが
/// 長時間埋まり、画面全体が固まって見える不具合があった（「実機で書き出しボタンが
/// 反応しない・画面がフリーズする」）。ここでやり取りする値（AVAsset/URL/CGSize等）は
/// どれもactor分離を必要としないので、重い処理だけをこのactorへ切り出し、
/// ExportManager側はawaitで呼ぶだけにする。await区間はこのactor自身の
/// バックグラウンド実行キューで動くため、メインスレッド＝UIの応答性をふさがない。
actor ExportWorker {

    /// このactorの仕事を走らせる専用のキュー（既定のcooperative thread poolは使わない）。
    ///
    /// 書き出しの中心は`AVAssetReader.copyNextSampleBuffer()`という**同期の**呼び出しで、
    /// フレームを1枚読むたびにAVFoundation内部のデコードスレッド（utility）を待つ。
    /// これを既定のcooperative thread poolで走らせると2つ困ることが起きる:
    ///
    ///   1. 書き出しが終わるまでプールのスレッドを1本占有し続ける
    ///      （他の並行処理――サムネイル生成や波形デコード――が詰まる）
    ///   2. 呼び出し側の優先度（画面からの操作＝user-initiated）へ引き上げられた状態で
    ///      utilityのスレッドを待つ形になり、優先度逆転になる
    ///      （Thread Performance Checkerが "waiting on a lower QoS thread" として報告する）
    ///
    /// 専用のキューを最初からutilityで持たせて、どちらも避ける。
    /// 書き出しは「進捗を見せながら裏で進む長い処理」なので、utilityが本来の優先度
    /// （ExportManagerが書き出しのTaskをutilityで起こしているのと揃えてある）。
    private nonisolated let queue = DispatchSerialQueue(
        label: "com.msmn1128.myvlogapp.export", qos: .utility
    )

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    // タイトルカード生成(createTitleCard/addTitleSfx)はExportWorker+TitleCard.swiftへ切り出してある。

    // MARK: - Per-clip processing

    // AVVideoCompositionCoreAnimationToolはCALayerの時刻管理がAVFoundation側の内部実装に
    // 依存していて、書き出しのたびに文字が数フレーム（時にはもっと）欠けることがある既知の
    // 不安定なAPI。何度か個別の緩和策を試したが根本解決しなかったため、CoreAnimationToolを
    // 完全に使わない方式へ作り直した：スケール・パディングの変換だけはAVFoundationの通常の
    // videoComposition（CoreAnimationToolなし）に任せ、そこから出てくる「すでにキャンバス
    // サイズへ変換済みのフレーム」に対して、こちらでフレームごとに毎回テキストを描き込む。
    // タイトルカード（renderTitleFrame）と同じ「自前でCGContextに描く」方式なので、
    // タイミングの不確実性が原理的に存在しない。

    /// - Parameter onProgress: このクリップ内の進み具合（0…1）。長いクリップ1本の間
    ///   進捗バーが止まって見えないよう、フレームの書き出しに合わせて呼ばれる
    ///   （Android: FFmpegの統計から進捗率を出しているのと同じ狙い）。
    ///   呼び出し回数は1%刻みに間引いてある
    func processClip(
        _ clip: VlogClip, silent: Bool, onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let asset  = try await AssetLoader.shared.load(clip: clip)
        let canvas = VlogLayout.canvasSize
        let videoTracks = try await asset.load(.tracks).filter { $0.mediaType == .video }
        guard let srcVideo = videoTracks.first else { throw ExportError.noVideoTrack }

        let trimRange = CMTimeRange(
            start: CMTime(value: clip.startMs, timescale: 1000),
            duration: CMTime(value: clip.trimmedDurationMs, timescale: 1000)
        )

        let videoOnlyURL = try await renderClipVideoWithText(
            clip: clip, asset: asset, sourceTrack: srcVideo, canvas: canvas,
            trimRange: trimRange, onProgress: onProgress
        )
        defer { try? FileManager.default.removeItem(at: videoOnlyURL) }

        // 音声はテキスト焼き込みと無関係で、通常のAVFoundation合成で安定して動く部分なので
        // そのまま使う（無音にしたいときは音声トラック自体を持たせない）。
        return try await mergeClipAudio(videoOnlyURL: videoOnlyURL, sourceAsset: asset, trimRange: trimRange, silent: silent)
    }

    /// スケール・パディング変換ずみの映像フレームを1枚ずつ取り出し、そこへテキストを
    /// 描き込みながら書き出す。変換自体はAVFoundationの通常のvideoComposition
    /// （CoreAnimationToolなし）に任せているので、変換ロジックは既存のものを流用できる。
    private func renderClipVideoWithText(
        clip: VlogClip, asset: AVAsset, sourceTrack: AVAssetTrack, canvas: CGSize,
        trimRange: CMTimeRange, onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let outURL = tempURL("clipvideo")
        let (reader, readerOutput) = try await makeClipReader(
            asset: asset, sourceTrack: sourceTrack, canvas: canvas, trimRange: trimRange
        )
        let (writer, writerInput, adaptor) = try makeClipWriter(to: outURL, canvas: canvas)

        guard reader.startReading() else { throw reader.error ?? ExportError.sessionCreationFailed }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // キャプション画像は区間ごとに1枚だけ作ってループの外に置く。
        // 中身は区間内のどのフレームでも同じなので、毎フレーム描き起こす必要がない
        let overlays = makeCaptionOverlays(
            canvas: canvas,
            spans: clip.visibleTextSpans(),   // trimStart起点の相対区間
            timeText: clip.timeText
        )
        // 進捗の分母。トリム区間の長さから見積もる（読み終わるまで実際の枚数は分からない）
        let expectedMs = max(1, clip.trimmedDurationMs)
        var reportedPercent = -1

        do {
            while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let srcBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

                // readerのtimeRangeで絞っても、返ってくるサンプルの時刻は元動画の絶対時刻の
                // ままなので、trimRange.startからの相対時刻に引き直してから書き出す
                let absolutePts  = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let relativeTime = CMTimeSubtract(absolutePts, trimRange.start)
                let relativeMs   = Int64(max(0, relativeTime.seconds) * 1000)

                try await waitUntilReady(writerInput)

                // 読み取り側のバッファは書き換えず、書き込み側のプールから借りた1枚へ
                // 写してから文字を重ねる（理由はcomposeFrameのコメント）
                guard let destBuffer = makeOutputBuffer(from: adaptor) else {
                    throw ExportError.pixelBufferPoolUnavailable
                }
                composeFrame(
                    source: srcBuffer, destination: destBuffer, canvas: canvas,
                    positionMs: relativeMs, overlays: overlays
                )
                adaptor.append(destBuffer, withPresentationTime: relativeTime)

                // 1%刻みでだけ知らせる。毎フレーム呼ぶと、受け取る側（@MainActorのExportManager）への
                // ホップが30fps×尺ぶん積み上がって、書き出し自体より重くなりかねない
                let percent = Int(Double(relativeMs) / Double(expectedMs) * 100)
                if percent > reportedPercent {
                    reportedPercent = percent
                    onProgress(min(1.0, Double(percent) / 100))
                }
            }

            // 読み取りが途中で失敗しても copyNextSampleBuffer は nil を返すだけで、ループはふつうに抜ける。
            // 確かめずに書き終えると、コマの足りない（時には1コマも無い）動画ができ、あとの工程で
            // 「長さを読めない」といった原因の分からないエラーになっていた。読み取りの失敗はここで伝える
            if reader.status == .failed { throw reader.error ?? ExportError.sessionCreationFailed }
            writerInput.markAsFinished()
            await writer.finishWriting()
            if let err = writer.error { throw err }
            return outURL
        } catch {
            // 中止（Task.checkCancellation）や失敗で抜けるときは、読み書きを明示的に畳む。
            // 畳まないとデコーダと書き込み中のファイルハンドルを掴んだまま解放され、
            // 書きかけのファイルも次の起動（cleanupOrphanedWorkFiles）まで残り続ける。
            // 呼び出し元（processClip）のdeferは戻り値の束縛後に設定されるため、
            // ここでthrowする経路では効かない
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
    }

    /// renderClipVideoWithTextの読み取り側セットアップ（AVAssetReader + スケール・
    /// パディング変換ずみのvideoCompositionを付けたAVAssetReaderVideoCompositionOutput）
    private func makeClipReader(
        asset: AVAsset, sourceTrack: AVAssetTrack, canvas: CGSize, trimRange: CMTimeRange
    ) async throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
        let assetDuration = try await asset.load(.duration)
        let videoComp = try await buildPlainVideoComposition(sourceTrack: sourceTrack, canvas: canvas, coverage: assetDuration)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = trimRange
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [sourceTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        readerOutput.videoComposition = videoComp
        guard reader.canAdd(readerOutput) else { throw ExportError.sessionCreationFailed }
        reader.add(readerOutput)
        return (reader, readerOutput)
    }

    /// writerが次のフレームを受け取れるようになるまで待つ。
    /// ExportWorker+TitleCard.swiftからも呼ぶためinternal。
    ///
    /// 以前は`while !input.isReadyForMoreMediaData { await Task.yield() }`で回していた。
    /// `Task.yield()`は「順番を譲る」だけで待たないので、受け取れない状態が続く間ずっと
    /// このタスクがスレッドを回し続ける（実質ビジーループ）。実際に空くまでには
    /// ミリ秒単位の時間がかかるため、短く眠って待つほうがCPUを食わない。
    /// 1ms刻みにしてあるのは、眠りすぎると書き出し自体が遅くなるため。
    ///
    /// `Task.sleep`は取りやめで投げるので、ここが素直に中止の反応点にもなる
    /// （以前のyieldでは、この待ちの最中に中止しても次のフレームまで反応しなかった）。
    func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    /// 書き込み側のプールから出力用のバッファを1枚借りる。
    /// プールは`writer.startWriting()`のあとに用意されるので、必ず開始後に呼ぶこと。
    private func makeOutputBuffer(from adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// renderClipVideoWithTextの書き出し側セットアップ（AVAssetWriter + Input + Adaptor）
    private func makeClipWriter(
        to url: URL, canvas: CGSize
    ) throws -> (AVAssetWriter, AVAssetWriterInput, AVAssetWriterInputPixelBufferAdaptor) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.h264Settings(canvas: canvas))
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: Self.pixelBufferAttributes(canvas: canvas)
        )
        writer.add(writerInput)
        return (writer, writerInput, adaptor)
    }

    /// createTitleCard(ExportWorker+TitleCard.swift)/makeClipWriterで共通のAVAssetWriterInput設定。
    /// ファイルをまたいで参照するためinternal
    ///
    /// - ビットレートは明示する（Android: MEDIACODEC_BITRATE_BPS と同じ12Mbps）。任せていると端末や
    ///   素材で変わり、書き出し前の空き容量の見積もり（ExportSpace）とも合わなくなる
    /// - 出力にBT.709の色空間の情報を付ける（Android: videoEncodeArgs）。付けないと再生する側が
    ///   変換式を推測し、BT.601と取られると色がずれる
    static func h264Settings(canvas: CGSize) -> [String: Any] {
        [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: ExportSpace.videoBitRate
            ],
            AVVideoColorPropertiesKey: rec709ColorProperties
        ]
    }

    /// BT.709（SDRの標準）の色空間の情報。書き出しの出力と、読み取り側の変換先の両方に使う
    static let rec709ColorProperties: [String: String] = [
        AVVideoColorPrimariesKey:   AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey:      AVVideoYCbCrMatrix_ITU_R_709_2
    ]

    /// createTitleCard(ExportWorker+TitleCard.swift)/makeClipWriterで共通の
    /// AVAssetWriterInputPixelBufferAdaptor設定。ファイルをまたいで参照するためinternal
    static func pixelBufferAttributes(canvas: CGSize) -> [String: Any] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String:  Int(canvas.width),
            kCVPixelBufferHeightKey as String: Int(canvas.height)
        ]
    }

    /// スケール・パディングだけを行う素のvideoComposition（CoreAnimationToolは付けない）。
    /// [coverage]はreaderのtimeRangeでの絞り込みに関係なく、元動画の絶対時刻でinstructionが
    /// 有効になる範囲。変換自体は時間に依存しないので、単に元動画全体をカバーしておけばよい。
    private func buildPlainVideoComposition(
        sourceTrack: AVAssetTrack, canvas: CGSize, coverage: CMTime
    ) async throws -> AVMutableVideoComposition {
        let naturalSize         = try await sourceTrack.load(.naturalSize)
        let preferredTransform  = try await sourceTrack.load(.preferredTransform)
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displayW = max(1, abs(displayRect.width))
        let displayH = max(1, abs(displayRect.height))

        let scale   = min(canvas.width / displayW, canvas.height / displayH)
        let scaledW = displayW * scale
        let scaledH = displayH * scale
        let tx = (canvas.width  - scaledW) / 2
        let ty = (canvas.height - scaledH) / 2

        let normalize = CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY)
        let scaleT    = CGAffineTransform(scaleX: scale, y: scale)
        let centerT   = CGAffineTransform(translationX: tx, y: ty)
        let finalT    = preferredTransform.concatenating(normalize).concatenating(scaleT).concatenating(centerT)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: coverage)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceTrack)
        layerInstruction.setTransform(finalT, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComp = AVMutableVideoComposition()
        videoComp.renderSize    = canvas
        videoComp.frameDuration = CMTime(value: 1, timescale: 30)
        videoComp.instructions  = [instruction]
        // 合成の色空間をBT.709（SDR）に決める。HDR（HLG・PQ）の素材は、AVFoundationがここへ
        // トーンマッピングしてから渡してくる（Android: Hdr.kt で zscale/tonemap しているのに当たる）。
        // 決めていないと、素材や端末しだいの色空間のまま8bitへ落とされ、白っぽく色が抜けうる
        videoComp.colorPrimaries        = AVVideoColorPrimaries_ITU_R_709_2
        videoComp.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComp.colorYCbCrMatrix      = AVVideoYCbCrMatrix_ITU_R_709_2
        return videoComp
    }

    /// 映像だけ焼き込みずみのファイルへ、元動画の音声（トリム区間ぶん）を合流させる。
    /// 無音にしたい場合は音声トラック自体を作らない（音量0のミックスより単純で確実）。
    private func mergeClipAudio(
        videoOnlyURL: URL, sourceAsset: AVAsset, trimRange: CMTimeRange, silent: Bool
    ) async throws -> URL {
        let videoOnlyAsset = AVURLAsset(url: videoOnlyURL)
        let videoDuration  = try await videoOnlyAsset.load(.duration)
        guard let videoOnlyTrack = try await videoOnlyAsset.loadTracks(withMediaType: .video).first else {
            throw ExportError.noVideoTrack
        }

        let composition = AVMutableComposition()
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.sessionCreationFailed
        }
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoOnlyTrack, at: .zero)

        if !silent {
            let srcAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
            if let srcAudio = srcAudioTracks.first {
                guard let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw ExportError.sessionCreationFailed
                }
                // 音声は映像と同じ長さまでにする（Android: apad → atrim で映像と同じ尺に強制するのと同じ）。
                // 素材の音声は映像より長いことがあり、そのまま入れるとクリップのファイルの長さが音声の長さに
                // なって、結合したとき次のクリップの映像がそのぶん後ろへずれ、映像に隙間ができていた
                // （映像1.0秒・音声1.3秒で、2本目の映像が1.3秒から始まった）。短いぶんは無音のままでよい
                let audioRange = try await srcAudio.load(.timeRange)
                let usable = CMTimeRangeGetIntersection(
                    CMTimeRange(start: trimRange.start, duration: CMTimeMinimum(trimRange.duration, videoDuration)),
                    otherRange: audioRange
                )
                if usable.duration > .zero {
                    try compAudio.insertTimeRange(usable, of: srcAudio, at: usable.start - trimRange.start)
                }
            }
        }

        let outURL = tempURL("clip")
        // compVideoはrenderClipVideoWithTextで既にキャンバスサイズへ変換済みの映像なので、
        // ここでは音声トラックを合流させるだけで済む。1920x1080プリセットで固定すると
        // 変換の必要が無い映像まで毎回再エンコードしてしまい、画質劣化と処理時間の両方で
        // 無駄が出る。可能ならパススルー（無劣化の再多重化）を使う
        // （Android版が個別エンコード→結合の2段構成をやめ、1回のエンコードに統合したのと同じ狙い）。
        let presetName = await bestExportPreset(for: composition, outputFileType: .mov, fallback: AVAssetExportPreset1920x1080)
        guard let session = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw ExportError.sessionCreationFailed
        }
        session.shouldOptimizeForNetworkUse = true
        do {
            try await session.export(to: outURL, as: .mov)
        } catch {
            // 中止・失敗したときに書きかけを残さない（renderClipVideoWithTextと同じ方針）
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
        return outURL
    }

    // MARK: - Concatenation

    func concatenate(urls: [URL]) async throws -> URL {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.sessionCreationFailed
        }

        var insertTime = CMTime.zero
        for url in urls {
            let asset   = AVURLAsset(url: url)
            let vTracks = try await asset.loadTracks(withMediaType: .video)
            let aTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let vt = vTracks.first else { throw ExportError.noVideoTrack }
            // 次のクリップは映像の長さぶん後ろに置く。ファイルの長さ（映像と音声の長い方）で進めると、
            // 音声が長いクリップのあとで映像に隙間ができる。音声も映像の長さまでで切る（Android: atrim）
            let videoRange = try await vt.load(.timeRange)
            let range = CMTimeRange(start: .zero, duration: videoRange.end)

            try videoTrack.insertTimeRange(range, of: vt, at: insertTime)
            if let at = aTracks.first {
                let usable = CMTimeRangeGetIntersection(range, otherRange: try await at.load(.timeRange))
                if usable.duration > .zero {
                    try audioTrack.insertTimeRange(usable, of: at, at: insertTime + usable.start)
                }
            }
            insertTime = insertTime + range.duration
        }

        // 出力はMP4なので拡張子も.mp4にする。中身と拡張子が食い違っていると、
        // 受け取り側（写真ライブラリ等）が拡張子からコンテナを推測して誤ることがある
        let outURL = tempURL("merged", ext: "mp4")
        // 各クリップは既にキャンバスサイズ・同じH264設定で書き出し済みなので、結合だけなら
        // パススルーで再エンコードなしに済ませられる（mergeClipAudioと同じ狙い）。
        let presetName = await bestExportPreset(for: composition, outputFileType: .mp4, fallback: AVAssetExportPreset1920x1080)
        guard let session = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw ExportError.sessionCreationFailed
        }
        session.shouldOptimizeForNetworkUse = true
        do {
            try await session.export(to: outURL, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
        return outURL
    }

    // MARK: - Save to camera roll

    /// - Parameter createdAt: 書き出した動画の作成日時。写真アプリの並び順と日付表示に使われる。
    ///   指定しないと、撮影日時を持たない素材として扱われて日付が不定になる
    ///   （Android版がMP4のcreation_timeとMediaStoreのDATE_TAKENへ書き出し時刻を
    ///   入れているのと同じ狙い。あちらは「入れないとMP4の起点=1904年と読める」とある）。
    func saveToPhotoLibrary(url: URL, displayName: String, createdAt: Date) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photoLibraryAccessDenied
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = createdAt
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = displayName
                request.addResource(with: .video, fileURL: url, options: options)
            }) { success, error in
                if success { cont.resume() }
                else { cont.resume(throwing: error ?? ExportError.saveToLibraryFailed) }
            }
        }
    }

    // MARK: - Helpers

    /// パススルー（無劣化の再多重化）が使えるか判定し、使えるなら
    /// AVAssetExportPresetPassthroughを、使えなければfallbackのプリセットを返す。
    /// AVAssetExportPresetPassthroughはallExportPresets()/exportPresets(compatibleWith:)には
    /// 出てこない特別な値なので、determineCompatibility(ofExportPreset:with:outputFileType:)で
    /// 個別に互換性を確認する必要がある（Apple公式ドキュメント記載の判定方法）。
    private func bestExportPreset(for asset: AVAsset, outputFileType: AVFileType, fallback: String) async -> String {
        let isPassthroughCompatible = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVAssetExportSession.determineCompatibility(
                ofExportPreset: AVAssetExportPresetPassthrough,
                with: asset,
                outputFileType: outputFileType
            ) { isCompatible in
                continuation.resume(returning: isCompatible)
            }
        }
        return isPassthroughCompatible ? AVAssetExportPresetPassthrough : fallback
    }

    /// 書き出しが作る一時ファイルの名前の頭。cleanupOrphanedWorkFilesが
    /// 「自分が作った残骸か」を見分けるのに使うので、tempURLに渡す名前はこれで始めること
    static let workFilePrefixes = ["clipvideo_", "clip_", "merged", "title"]

    /// ExportWorker+TitleCard.swiftからも参照するためinternal。
    ///
    /// - Parameter ext: 出力コンテナに合わせた拡張子。中身と食い違うと、受け取り側が
    ///   拡張子からコンテナを推測して誤ることがある。
    ///
    /// 名前に短い乱数を足してあるのは、時刻が秒単位なので同じ名前の作業ファイルが
    /// 同じ秒内に2つできると衝突するため（`workFilePrefixes`での見分けは頭の名前だけを見る）。
    func tempURL(_ name: String, ext: String = "mov") -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(stamp)_\(UUID().uuidString.prefix(8)).\(ext)")
    }

    /// 前回、書き出し中にアプリが強制終了したときに残った作業ファイルを掃除する
    /// （Android: VlogExporter.cleanupOrphanedWorkFiles）。
    ///
    /// runExportは成功・失敗どちらの経路でも一時ファイルを消すが、プロセスごと落とされると
    /// 残る。結合途中の動画は数GBになりうるため、起動時に掃除する。
    ///
    /// - Parameter createdBefore: これより前に作られたファイルだけを消す（アプリを起動した時刻を渡す）。
    ///   いま走っている書き出しのファイルは起動より後に作られるので、掃除が遅れて走っても消さない
    nonisolated static func cleanupOrphanedWorkFiles(createdBefore: Date) {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: tempDir, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries where url.pathExtension == "mov" || url.pathExtension == "mp4" {
            let name = url.lastPathComponent
            guard workFilePrefixes.contains(where: { name.hasPrefix($0) }) else { continue }
            // 作成日時が読めないファイルは、今回の書き出しのものかもしれないので消さない
            guard let createdAt = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  createdAt < createdBefore else { continue }
            try? fm.removeItem(at: url)
        }
    }
}
