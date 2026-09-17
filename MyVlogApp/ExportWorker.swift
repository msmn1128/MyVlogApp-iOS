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

    func processClip(_ clip: VlogClip, silent: Bool) async throws -> URL {
        let asset  = try await AssetLoader.shared.load(clip: clip)
        let canvas = VlogLayout.canvasSize
        let videoTracks = try await asset.load(.tracks).filter { $0.mediaType == .video }
        guard let srcVideo = videoTracks.first else { throw ExportError.noVideoTrack }

        let trimRange = CMTimeRange(
            start: CMTime(value: clip.startMs, timescale: 1000),
            duration: CMTime(value: clip.trimmedDurationMs, timescale: 1000)
        )

        let videoOnlyURL = try await renderClipVideoWithText(
            clip: clip, asset: asset, sourceTrack: srcVideo, canvas: canvas, trimRange: trimRange
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
        clip: VlogClip, asset: AVAsset, sourceTrack: AVAssetTrack, canvas: CGSize, trimRange: CMTimeRange
    ) async throws -> URL {
        let outURL = tempURL("clipvideo_\(clip.id.uuidString)")
        let (reader, readerOutput) = try await makeClipReader(
            asset: asset, sourceTrack: sourceTrack, canvas: canvas, trimRange: trimRange
        )
        let (writer, writerInput, adaptor) = try makeClipWriter(to: outURL, canvas: canvas)

        guard reader.startReading() else { throw reader.error ?? ExportError.sessionCreationFailed }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let spans    = clip.visibleTextSpans()   // trimStart起点の相対区間
        let timeText = clip.timeText

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let srcBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            // readerのtimeRangeで絞っても、返ってくるサンプルの時刻は元動画の絶対時刻の
            // ままなので、trimRange.startからの相対時刻に引き直してから書き出す
            let absolutePts  = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let relativeTime = CMTimeSubtract(absolutePts, trimRange.start)
            let relativeMs   = Int64(max(0, relativeTime.seconds) * 1000)

            while !writerInput.isReadyForMoreMediaData { await Task.yield() }

            drawCaptionOverlay(onto: srcBuffer, canvas: canvas, positionMs: relativeMs, spans: spans, timeText: timeText)
            adaptor.append(srcBuffer, withPresentationTime: relativeTime)
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        if let err = writer.error { throw err }
        return outURL
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
    static func h264Settings(canvas: CGSize) -> [String: Any] {
        [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height)
        ]
    }

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
                try? compAudio.insertTimeRange(trimRange, of: srcAudio, at: .zero)
            }
        }

        let outURL = tempURL("clip_\(UUID().uuidString)")
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
        try await session.export(to: outURL, as: .mov)
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
            let asset    = AVURLAsset(url: url)
            let vTracks  = try await asset.load(.tracks).filter { $0.mediaType == .video }
            let aTracks  = try await asset.load(.tracks).filter { $0.mediaType == .audio }
            let duration = try await asset.load(.duration)
            let range    = CMTimeRange(start: .zero, duration: duration)

            if let vt = vTracks.first { try videoTrack.insertTimeRange(range, of: vt, at: insertTime) }
            if let at = aTracks.first { try? audioTrack.insertTimeRange(range, of: at, at: insertTime) }
            insertTime = insertTime + duration
        }

        let outURL = tempURL("merged")
        // 各クリップは既にキャンバスサイズ・同じH264設定で書き出し済みなので、結合だけなら
        // パススルーで再エンコードなしに済ませられる（mergeClipAudioと同じ狙い）。
        let presetName = await bestExportPreset(for: composition, outputFileType: .mp4, fallback: AVAssetExportPreset1920x1080)
        guard let session = AVAssetExportSession(asset: composition, presetName: presetName) else {
            throw ExportError.sessionCreationFailed
        }
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: outURL, as: .mp4)
        return outURL
    }

    // MARK: - Save to camera roll

    /// 写真アプリでの表示名「Vlog_<タイトル文言>.mp4」を組み立てる（Android: buildDisplayName
    /// と同じ方針。既定は撮影日、タイトルを自由入力していればそちらを使う）。Android版は
    /// 同名チェックにMediaStoreの自アプリファイルを権限なしで参照できるが、iOSで同等の
    /// 重複チェックをするにはPHPhotoLibraryの読み取り権限（.addOnlyより広い権限）が追加で
    /// 必要になり、書き出しのたびに権限ダイアログが増えてしまう。その副作用の方が実害が
    /// 大きいため、重複チェックは行わずベース名をそのまま使う
    /// （同名ファイルがあってもPhotosアプリ側でファイル名の衝突は解決される）。
    func displayName(titleText: String) -> String {
        "Vlog_\(sanitizeForFileName(titleText)).mp4"
    }

    /// タイトル文言をファイル名の一部として使える形にする
    /// （改行・パス区切りの除去、長さの切り詰め。Android: sanitizeForFileName）
    private func sanitizeForFileName(_ titleText: String) -> String {
        let singleLine = titleText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPathChars = singleLine.replacingOccurrences(
            of: "[\\\\/:*?\"<>|]", with: "-", options: .regularExpression
        )
        let truncated = String(withoutPathChars.prefix(VlogLayout.titleFilenameMaxChars))
        return truncated.isEmpty ? "Untitled" : truncated
    }

    func saveToPhotoLibrary(url: URL, displayName: String) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photoLibraryAccessDenied
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
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

    /// ExportWorker+TitleCard.swiftからも参照するためinternal
    func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(Int(Date().timeIntervalSince1970)).mov")
    }
}
