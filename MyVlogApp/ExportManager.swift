import AVFoundation
import Combine
import UIKit
import Photos
import UserNotifications

// MARK: - ExportManager

@MainActor
class ExportManager: ObservableObject {
    @Published var isExporting: Bool   = false
    @Published var progress:    Double = 0
    @Published var message:     String = ""

    private var exportTask: Task<Void, Never>?
    /// アプリがバックグラウンドへ回っても書き出しを続けるための延命申請
    /// （Android: VlogExportServiceのフォアグラウンドサービス化に相当）
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func startExport(clips: [VlogClip], timelineMuted: Bool = false, includeTitle: Bool = true) {
        guard !isExporting, !clips.isEmpty else { return }
        isExporting = true
        progress    = 0
        message     = includeTitle ? "タイトルを作成中..." : "クリップを処理中..."
        beginBackgroundTask()
        exportTask  = Task { await runExport(clips: clips, timelineMuted: timelineMuted, includeTitle: includeTitle) }
    }

    func cancel() {
        exportTask?.cancel()
        isExporting = false
        endBackgroundTask()
    }

    // MARK: - Background execution

    private func beginBackgroundTask() {
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VlogExport") { [weak self] in
            // OSに与えられた延長時間を使い切った＝ここで畳むしかない
            self?.exportTask?.cancel()
            self?.endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    /// 書き出し完了をローカル通知で知らせる（Android: 完了時のToast「ギャラリーに保存しました」相当。
    /// バックグラウンドで書き出しが終わった場合に特に役立つ）
    private func notifyCompletion(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body  = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - Main pipeline

    private func runExport(clips: [VlogClip], timelineMuted: Bool, includeTitle: Bool) async {
        var tempFiles: [URL] = []
        do {
            // タイトルカードは常に作る（タイトル無し書き出しの先頭クリップだけ文字が
            // 数フレーム欠ける不具合の回避策。タイトル役の映像を経由すると解消するため、
            // 生成はそのまま行い、不要な場合は結合後にその区間だけ切り落とす）。
            update("タイトルを作成中...")
            var titleURL = try await createTitleCard(clips: clips)
            tempFiles.append(titleURL)
            if !timelineMuted {
                let withSfx = try await addTitleSfx(to: titleURL)
                tempFiles.append(withSfx)
                titleURL = withSfx
            }
            guard !Task.isCancelled else { throw CancellationError() }

            var clipURLs: [URL] = [titleURL]
            let progressDenominator = Double(clips.count + 2)
            for (i, clip) in clips.enumerated() {
                update("クリップ \(i + 1)/\(clips.count) を処理中...")
                let url = try await processClip(clip, silent: clip.isSilentInExport(timelineMuted: timelineMuted))
                clipURLs.append(url)
                tempFiles.append(url)
                progress = Double(i + 1) / progressDenominator
                guard !Task.isCancelled else { throw CancellationError() }
            }

            update("結合中...")
            var merged = try await concatenate(urls: clipURLs)
            tempFiles.append(merged)
            progress = 0.9

            if !includeTitle {
                update("タイトルを取り除いています...")
                let stripped = try await stripTitleSegment(from: merged)
                tempFiles.append(stripped)
                merged = stripped
            }

            update("保存中...")
            try await saveToPhotoLibrary(url: merged)
            progress = 1.0
            update("完了")
            notifyCompletion(title: "書き出し完了", body: "ギャラリーに保存しました")
        } catch is CancellationError {
            update("")
        } catch {
            update("エラー: \(error.localizedDescription)")
            notifyCompletion(title: "書き出しに失敗しました", body: error.localizedDescription)
        }
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        isExporting = false
        endBackgroundTask()
    }

    // MARK: - Title card (AVAssetWriter, 2s black + text)

    private func createTitleCard(clips: [VlogClip]) async throws -> URL {
        let url = tempURL("title_card")
        let size = CGSize(width: 1920, height: 1080)
        let fps: Int32 = 30
        let totalFrames = Int(VlogLayout.titleCardDuration * Double(fps))  // 60 frames

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  1920,
            AVVideoHeightKey: 1080
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:  1920,
                kCVPixelBufferHeightKey as String: 1080
            ]
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
    private func addTitleSfx(to videoURL: URL) async throws -> URL {
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

    private func renderTitleFrame(size: CGSize, frame: Int, total: Int, dateText: String) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height),
                            kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let pb = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return pb }

        // Fade: frames 30-49 (spec: frames 31-50 are 1-indexed)
        let fadeStart = 30, fadeEnd = 50
        let alpha: CGFloat = frame < fadeStart ? 1.0
            : frame >= fadeEnd ? 0.0
            : 1.0 - CGFloat(frame - fadeStart) / CGFloat(fadeEnd - fadeStart)

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            // Black background
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            guard alpha > 0 else { return }

            // Line 1: "Vlog."（Android: TITLE_FONT_PT / TITLE_Y_OFFSET_PT、中央から-70ptずらす）
            let vlogFont = UIFont(name: VlogFonts.logoTypeName, size: VlogLayout.titleVlogFontSize)
                ?? UIFont.systemFont(ofSize: VlogLayout.titleVlogFontSize, weight: .regular)
            let vlogAttrs: [NSAttributedString.Key: Any] = [
                .font:            vlogFont,
                .foregroundColor: UIColor.white.withAlphaComponent(alpha)
            ]
            let vlogStr = NSAttributedString(string: "Vlog.", attributes: vlogAttrs)
            let vlogSize = vlogStr.size()

            // Line 2: dateText（Android: TITLE_DATE_FONT_PT / TITLE_DATE_Y_OFFSET_PT、+80ptずらす）
            let dateFont = UIFont(name: VlogFonts.timeFontName, size: VlogLayout.titleDateFontSize)
                ?? UIFont.systemFont(ofSize: VlogLayout.titleDateFontSize, weight: .light)
            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font:            dateFont,
                .foregroundColor: UIColor.white.withAlphaComponent(alpha)
            ]
            let dateStr = NSAttributedString(string: dateText, attributes: dateAttrs)
            let dateSize = dateStr.size()

            // Android centeredY(offsetPt) = (h-text_h)/2 + offsetPt をそのまま踏襲
            let vlogY = (size.height - vlogSize.height) / 2 + VlogLayout.titleVlogYOffset
            let dateY = (size.height - dateSize.height) / 2 + VlogLayout.titleDateYOffset

            vlogStr.draw(in: CGRect(
                x: (size.width - vlogSize.width) / 2,
                y: vlogY,
                width: vlogSize.width,
                height: vlogSize.height
            ))

            dateStr.draw(in: CGRect(
                x: (size.width - dateSize.width) / 2,
                y: dateY,
                width: dateSize.width,
                height: dateSize.height
            ))
        }

        if let cgImage = image.cgImage {
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }

        return pb
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

    private func processClip(_ clip: VlogClip, silent: Bool) async throws -> URL {
        let asset  = try await AssetLoader.shared.load(clip: clip)
        let canvas = CGSize(width: 1920, height: 1080)
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

        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mov)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(canvas.width),
            AVVideoHeightKey: Int(canvas.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:  Int(canvas.width),
                kCVPixelBufferHeightKey as String: Int(canvas.height)
            ]
        )
        writer.add(writerInput)

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

    /// すでにキャンバスサイズへ変換済みのフレーム（BGRA）に、直接「ひとこと」と時刻を描き込む。
    private func drawCaptionOverlay(
        onto pixelBuffer: CVPixelBuffer, canvas: CGSize,
        positionMs: Int64, spans: [(spanStart: Int64, spanEnd: Int64, text: String)], timeText: String
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(canvas.width), height: Int(canvas.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        // 透明背景のオーバーレイ画像を作り、既存フレームの上へアルファ合成で重ねる
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale  = 1
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        let overlay = renderer.image { _ in
            if let activeText = spans.first(where: { positionMs >= $0.spanStart && positionMs < $0.spanEnd })?.text {
                drawHitokoto(activeText, canvas: canvas)
            }
            drawTimestamp(timeText, canvas: canvas)
        }
        if let cgImage = overlay.cgImage {
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: canvas))
        }
    }

    /// 「ひとこと」：上下左右中央、複数行対応（Android: HITOKOTO_FONT_PT / LINE_SPACING）
    private func drawHitokoto(_ text: String, canvas: CGSize) {
        let font = UIFont(name: VlogFonts.logoTypeName, size: VlogLayout.hitokoroFontSize)
            ?? UIFont.boldSystemFont(ofSize: VlogLayout.hitokoroFontSize)
        let lineH = VlogLayout.hitokoroFontSize + VlogLayout.hitokoroLineGap
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let totalH = CGFloat(lines.count) * lineH - VlogLayout.hitokoroLineGap
        let topY   = canvas.height * 0.5 - totalH / 2

        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        for (idx, line) in lines.enumerated() where !line.isEmpty {
            let str  = NSAttributedString(string: line, attributes: attrs)
            let size = str.size()
            let slotY = topY + CGFloat(idx) * lineH
            str.draw(in: CGRect(
                x: (canvas.width - size.width) / 2,
                y: slotY + (lineH - size.height) / 2,
                width: size.width, height: size.height
            ))
        }
    }

    /// 撮影時刻：上下中央・キャンバス右端基準（Android: TIME_FONT_PT / TIME_MARGIN_PT）
    private func drawTimestamp(_ text: String, canvas: CGSize) {
        let font = UIFont(name: VlogFonts.timeFontName, size: VlogLayout.timestampFontSize)
            ?? UIFont.monospacedSystemFont(ofSize: VlogLayout.timestampFontSize, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white]
        let str  = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        str.draw(in: CGRect(
            x: canvas.width - VlogLayout.timestampRightPad - size.width,
            y: (canvas.height - size.height) / 2,
            width: size.width, height: size.height
        ))
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

    private func concatenate(urls: [URL]) async throws -> URL {
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

    /// 結合済み動画の先頭（タイトルカードぶん）を切り落とす。タイトルカードは常に
    /// 生成した上でここで除くことで、タイトル無し書き出しの先頭クリップだけ文字が
    /// 数フレーム欠けていた不具合を避ける。
    private func stripTitleSegment(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let totalDuration = try await asset.load(.duration)
        let titleDuration = CMTime(seconds: VlogLayout.titleCardDuration, preferredTimescale: 600)
        guard totalDuration > titleDuration else { return url }

        let outURL = tempURL("no_title")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            return url
        }
        session.timeRange = CMTimeRange(start: titleDuration, duration: totalDuration - titleDuration)
        try await session.export(to: outURL, as: .mp4)
        return outURL
    }

    // MARK: - Save to camera roll

    private func saveToPhotoLibrary(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photoLibraryAccessDenied
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
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

    private func update(_ msg: String) {
        message = msg
    }

    static func videoRect(clip: VlogClip, canvas: CGSize) -> CGRect {
        let vW = CGFloat(max(1, clip.width))
        let vH = CGFloat(max(1, clip.height))
        let clipAR   = vW / vH
        let canvasAR = canvas.width / canvas.height
        if clipAR > canvasAR {
            let h = canvas.width / clipAR
            return CGRect(x: 0, y: (canvas.height - h) / 2, width: canvas.width, height: h)
        } else {
            let w = canvas.height * clipAR
            return CGRect(x: (canvas.width - w) / 2, y: 0, width: w, height: canvas.height)
        }
    }
}

// MARK: - Errors

enum ExportError: LocalizedError {
    case noVideoTrack
    case sessionCreationFailed
    case saveToLibraryFailed
    case photoLibraryAccessDenied

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:              return "動画トラックが見つかりません"
        case .sessionCreationFailed:     return "エクスポートセッションを作成できません"
        case .saveToLibraryFailed:       return "カメラロールへの保存に失敗しました"
        case .photoLibraryAccessDenied:  return "写真ライブラリへの保存権限がありません。設定アプリから許可してください。"
        }
    }
}
