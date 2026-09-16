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

    // MARK: - Title card (AVAssetWriter, 2s black + text)

    func createTitleCard(clips: [VlogClip]) async throws -> URL {
        let url = tempURL("title_card")
        let size = VlogLayout.canvasSize
        let fps: Int32 = 30
        let totalFrames = Int(VlogLayout.titleCardDuration * Double(fps))  // 60 frames

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: Self.h264Settings(canvas: size))
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: Self.pixelBufferAttributes(canvas: size)
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let dateText = clips.first?.dateText ?? ""
        for frameIdx in 0..<totalFrames {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData { await Task.yield() }
            let t = CMTime(value: CMTimeValue(frameIdx), timescale: fps)
            if let buffer = renderTitleFrame(size: size, frame: frameIdx, total: totalFrames, dateText: dateText) {
                adaptor.append(buffer, withPresentationTime: t)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let err = writer.error { throw err }
        return url
    }

    /// タイトルカード（映像のみ）にtitle.mp3を合成する。
    /// SFXはTITLE_SFX_FRAME_NUMBERフレーム目（30fpsなので約0.67秒後）から鳴り始め、
    /// タイトルカードの尺ぴったりに切る（Android: titleSfxDelayMs / atrim相当）。
    func addTitleSfx(to videoURL: URL) async throws -> URL {
        guard let sfxURL = Bundle.main.url(forResource: "title", withExtension: "mp3") else {
            return videoURL
        }

        let videoAsset = AVURLAsset(url: videoURL)
        let sfxAsset   = AVURLAsset(url: sfxURL)
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sfxTrack   = try await sfxAsset.loadTracks(withMediaType: .audio).first else {
            return videoURL
        }

        let composition = AVMutableComposition()
        let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let videoDuration = try await videoAsset.load(.duration)
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)

        let delaySeconds = Double(VlogLayout.titleSfxFrameNumber - 1) / 30.0
        let delayTime    = CMTime(seconds: delaySeconds, preferredTimescale: 600)
        let remaining    = videoDuration - delayTime
        if remaining > .zero {
            let sfxDuration  = try await sfxAsset.load(.duration)
            let clippedRange = CMTimeRange(start: .zero, duration: min(sfxDuration, remaining))
            let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try compAudio.insertTimeRange(clippedRange, of: sfxTrack, at: delayTime)
        }

        let outURL = tempURL("title_with_sfx")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return videoURL
        }
        session.outputFileType = .mov
        try await session.export(to: outURL, as: .mov)
        return outURL
    }

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

    /// createTitleCard/makeClipWriterで共通のAVAssetWriterInput設定
    private static func h264Settings(canvas: CGSize) -> [String: Any] {
        [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height)
        ]
    }

    /// createTitleCard/makeClipWriterで共通のAVAssetWriterInputPixelBufferAdaptor設定
    private static func pixelBufferAttributes(canvas: CGSize) -> [String: Any] {
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
        let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoOnlyTrack, at: .zero)

        if !silent {
            let srcAudioTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
            if let srcAudio = srcAudioTracks.first {
                let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
                try? compAudio.insertTimeRange(trimRange, of: srcAudio, at: .zero)
            }
        }

        let outURL = tempURL("clip_\(UUID().uuidString)")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            throw ExportError.sessionCreationFailed
        }
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: outURL, as: .mov)
        return outURL
    }

    // MARK: - Concatenation

    func concatenate(urls: [URL]) async throws -> URL {
        let composition = AVMutableComposition()
        let videoTrack  = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)!
        let audioTrack  = composition.addMutableTrack(withMediaType: .audio,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid)!

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
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            throw ExportError.sessionCreationFailed
        }
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: outURL, as: .mp4)
        return outURL
    }

    // MARK: - Save to camera roll

    /// 写真アプリでの表示名「Vlog_yyyy-MM-dd.mp4」を組み立てる（Android: buildDisplayNameの
    /// ベース名部分のみ移植）。Android版は同名チェックにMediaStoreの自アプリファイルを権限なしで
    /// 参照できるが、iOSで同等の重複チェックをするにはPHPhotoLibraryの読み取り権限
    /// （.addOnlyより広い権限）が追加で必要になり、書き出しのたびに権限ダイアログが増えてしまう。
    /// その副作用の方が実害が大きいため、重複チェックは行わずベース名をそのまま使う
    /// （同名ファイルがあってもPhotosアプリ側でファイル名の衝突は解決される）。
    func displayName(firstClipDateText: String) -> String {
        "Vlog_\(firstClipDateText.replacingOccurrences(of: "/", with: "-")).mp4"
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

    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(Int(Date().timeIntervalSince1970)).mov")
    }
}
