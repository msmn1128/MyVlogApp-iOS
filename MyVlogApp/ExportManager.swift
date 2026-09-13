import AVFoundation
import Combine
import UIKit
import Photos

// MARK: - ExportManager

@MainActor
class ExportManager: ObservableObject {
    @Published var isExporting: Bool   = false
    @Published var progress:    Double = 0
    @Published var message:     String = ""

    private var exportTask: Task<Void, Never>?

    func startExport(clips: [VlogClip], timelineMuted: Bool = false) {
        guard !isExporting, !clips.isEmpty else { return }
        isExporting = true
        progress    = 0
        message     = "タイトルを作成中..."
        exportTask  = Task { await runExport(clips: clips, timelineMuted: timelineMuted) }
    }

    func cancel() {
        exportTask?.cancel()
        isExporting = false
    }

    // MARK: - Main pipeline

    private func runExport(clips: [VlogClip], timelineMuted: Bool) async {
        var tempFiles: [URL] = []
        do {
            update("タイトルを作成中...")
            let titleURL = try await createTitleCard(clips: clips)
            tempFiles.append(titleURL)
            guard !Task.isCancelled else { throw CancellationError() }

            var clipURLs: [URL] = [titleURL]
            for (i, clip) in clips.enumerated() {
                update("クリップ \(i + 1)/\(clips.count) を処理中...")
                let url = try await processClip(clip, silent: clip.isSilentInExport(timelineMuted: timelineMuted))
                clipURLs.append(url)
                tempFiles.append(url)
                progress = Double(i + 1) / Double(clips.count + 2)
                guard !Task.isCancelled else { throw CancellationError() }
            }

            update("結合中...")
            let merged = try await concatenate(urls: clipURLs)
            tempFiles.append(merged)
            progress = 0.9

            update("保存中...")
            try await saveToPhotoLibrary(url: merged)
            progress = 1.0
            update("完了")
        } catch is CancellationError {
            update("")
        } catch {
            update("エラー: \(error.localizedDescription)")
        }
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        isExporting = false
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

    private func processClip(_ clip: VlogClip, silent: Bool) async throws -> URL {
        let asset   = try await AssetLoader.shared.load(clip: clip)
        let outURL  = tempURL("clip_\(clip.id.uuidString)")
        let canvas  = CGSize(width: 1920, height: 1080)

        // Build composition
        let composition  = AVMutableComposition()
        let videoTracks  = try await asset.load(.tracks).filter { $0.mediaType == .video }
        let audioTracks  = try await asset.load(.tracks).filter { $0.mediaType == .audio }
        guard let srcVideo = videoTracks.first else { throw ExportError.noVideoTrack }

        let trimRange = CMTimeRange(
            start: CMTime(value: clip.startMs, timescale: 1000),
            duration: CMTime(value: clip.trimmedDurationMs, timescale: 1000)
        )

        let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try compVideo.insertTimeRange(trimRange, of: srcVideo, at: .zero)

        var compAudio: AVMutableCompositionTrack?
        if let srcAudio = audioTracks.first {
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try? track.insertTimeRange(trimRange, of: srcAudio, at: .zero)
            compAudio = track
        }

        // Video composition for scaling + text overlay
        let videoComp = try await buildVideoComposition(
            composition:    composition,
            sourceTrack:    srcVideo,
            clip:           clip,
            canvas:         canvas
        )

        // Export
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1920x1080) else {
            throw ExportError.sessionCreationFailed
        }
        session.videoComposition   = videoComp
        session.shouldOptimizeForNetworkUse = true

        // クリップ個別またはタイムライン全体のミュート（Android: isSilentInExport）を音量0で反映
        if silent, let compAudio {
            let params = AVMutableAudioMixInputParameters(track: compAudio)
            params.setVolume(0, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            session.audioMix = mix
        }

        try await session.export(to: outURL, as: .mov)
        return outURL
    }

    private func buildVideoComposition(
        composition:  AVMutableComposition,
        sourceTrack:  AVAssetTrack,
        clip:         VlogClip,
        canvas:       CGSize
    ) async throws -> AVMutableVideoComposition {

        let naturalSize   = try await sourceTrack.load(.naturalSize)
        let preferredTransform = try await sourceTrack.load(.preferredTransform)
        let displayRect   = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let displayW      = max(1, abs(displayRect.width))
        let displayH      = max(1, abs(displayRect.height))

        let scale  = min(canvas.width / displayW, canvas.height / displayH)
        let scaledW = displayW * scale
        let scaledH = displayH * scale
        let tx      = (canvas.width  - scaledW) / 2
        let ty      = (canvas.height - scaledH) / 2

        // Combined transform: rotate → normalize → scale → center
        let normalize = CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY)
        let scaleT    = CGAffineTransform(scaleX: scale, y: scale)
        let centerT   = CGAffineTransform(translationX: tx, y: ty)
        let finalT    = preferredTransform.concatenating(normalize).concatenating(scaleT).concatenating(centerT)

        let compositionTracks = composition.tracks(withMediaType: .video)
        guard let compVideoTrack = compositionTracks.first else { throw ExportError.noVideoTrack }

        let instruction     = AVMutableVideoCompositionInstruction()
        let compDuration    = composition.duration
        instruction.timeRange = CMTimeRange(start: .zero, duration: compDuration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compVideoTrack)
        layerInstruction.setTransform(finalT, at: .zero)
        instruction.layerInstructions = [layerInstruction]

        let videoComp             = AVMutableVideoComposition()
        videoComp.renderSize      = canvas
        videoComp.frameDuration   = CMTime(value: 1, timescale: 30)
        videoComp.instructions    = [instruction]

        // Text overlay via Core Animation
        let totalSec = compDuration.seconds
        let animLayer = buildTextLayer(clip: clip, canvas: canvas, totalSeconds: totalSec)
        if let animLayer {
            let videoLayer = CALayer()
            videoLayer.frame = CGRect(origin: .zero, size: canvas)
            animLayer.insertSublayer(videoLayer, at: 0)
            videoComp.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: animLayer
            )
        }

        return videoComp
    }

    private func buildTextLayer(clip: VlogClip, canvas: CGSize, totalSeconds: Double) -> CALayer? {
        guard !clip.texts.isEmpty else { return nil }
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: canvas)
        parent.isGeometryFlipped = true  // use UIKit-like top-left origin

        let spans  = clip.visibleTextSpans()   // relative to trimStart
        let lineH  = VlogLayout.hitokoroFontSize + VlogLayout.hitokoroLineGap
        let font   = UIFont(name: VlogFonts.logoTypeName, size: VlogLayout.hitokoroFontSize)
            ?? UIFont.boldSystemFont(ofSize: VlogLayout.hitokoroFontSize)

        for span in spans {
            let startSec = Double(span.spanStart) / 1000.0
            let endSec   = Double(span.spanEnd)   / 1000.0
            let lines    = span.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let totalH   = CGFloat(lines.count) * lineH - VlogLayout.hitokoroLineGap
            let topY     = canvas.height * 0.5 - totalH / 2  // 上下左右中央

            for (lineIdx, line) in lines.enumerated() {
                guard !line.isEmpty else { continue }
                let tl  = CATextLayer()
                tl.string   = line
                tl.font     = font
                tl.fontSize = VlogLayout.hitokoroFontSize
                tl.foregroundColor = UIColor.white.cgColor
                tl.alignmentMode   = .center
                tl.contentsScale   = 1
                let y = topY + CGFloat(lineIdx) * lineH
                tl.frame = CGRect(x: 0, y: y, width: canvas.width, height: lineH)
                tl.opacity = 0

                addBinaryOpacityAnimation(layer: tl, show: startSec, hide: endSec, total: totalSeconds)
                parent.addSublayer(tl)
            }
        }

        // Timestamp: 上下中央・右端 (right-aligned, vertically centered)
        let tsFont = UIFont(name: VlogFonts.timeFontName, size: VlogLayout.timestampFontSize)
            ?? UIFont.monospacedSystemFont(ofSize: VlogLayout.timestampFontSize, weight: .medium)
        let tsTL   = CATextLayer()
        tsTL.string          = clip.timeText
        tsTL.font            = tsFont
        tsTL.fontSize        = VlogLayout.timestampFontSize
        tsTL.alignmentMode   = .right
        tsTL.foregroundColor = UIColor.white.cgColor
        tsTL.contentsScale   = 1
        // Layer right edge = canvas right - rightPad; wide enough for any HH:mm
        let tsW: CGFloat     = 300
        let tsRightEdge      = canvas.width - VlogLayout.timestampRightPad
        let tsY              = canvas.height * 0.5 - VlogLayout.timestampFontSize * 0.7
        tsTL.frame           = CGRect(x: tsRightEdge - tsW, y: tsY,
                                      width: tsW, height: VlogLayout.timestampFontSize * 1.4)
        tsTL.opacity         = 1
        parent.addSublayer(tsTL)

        return parent
    }

    private func addBinaryOpacityAnimation(layer: CALayer, show: Double, hide: Double, total: Double) {
        guard total > 0 else { layer.opacity = 1; return }
        let s = max(0.0, min(total, show))
        let h = max(0.0, min(total, hide))
        guard s < h else { layer.opacity = 0; return }

        var times:  [Double] = []
        var values: [Float]  = []

        if s <= 0 {
            times.append(0.0)
            values.append(1.0)
        } else {
            times.append(0.0)
            values.append(0.0)
            times.append(s / total)
            values.append(1.0)
        }

        if h < total {
            times.append(h / total)
            values.append(0.0)
            times.append(1.0)
            values.append(0.0)
        } else {
            times.append(1.0)
            values.append(1.0)
        }

        var sanitizedTimes: [Double] = []
        var sanitizedValues: [Float] = []
        for i in 0..<times.count {
            let t = max(0.0, min(1.0, times[i]))
            if let lastT = sanitizedTimes.last {
                if t > lastT {
                    sanitizedTimes.append(t)
                    sanitizedValues.append(values[i])
                } else if t == lastT {
                    sanitizedValues[sanitizedValues.count - 1] = values[i]
                }
            } else {
                sanitizedTimes.append(t)
                sanitizedValues.append(values[i])
            }
        }
        if sanitizedTimes.first != 0.0 {
            sanitizedTimes.insert(0.0, at: 0)
            sanitizedValues.insert(values.first ?? 0, at: 0)
        }
        if sanitizedTimes.last != 1.0 {
            sanitizedTimes.append(1.0)
            sanitizedValues.append(sanitizedValues.last ?? 0)
        }

        let kf = CAKeyframeAnimation(keyPath: "opacity")
        kf.calculationMode = .discrete
        kf.keyTimes  = sanitizedTimes.map  { NSNumber(value: $0) }
        kf.values    = sanitizedValues.map { NSNumber(value: $0) }
        kf.duration  = total
        kf.beginTime = AVCoreAnimationBeginTimeAtZero
        kf.isRemovedOnCompletion = false
        kf.fillMode  = .both
        layer.add(kf, forKey: "opacity")
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
