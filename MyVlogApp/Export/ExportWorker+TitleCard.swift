import AVFoundation

// =====================================================================================
// ExportWorker.swiftからの切り出し。タイトルカード映像の生成(createTitleCard)と
// タイトルSFXの合成(addTitleSfx)だけをまとめたもの。テキスト焼き込みの描画処理が
// ExportWorker+Drawing.swiftへ分離されているのと同じ考え方で、書き出しパイプラインの
// 中でも独立した工程として切り出せる部分をここへ置く。
// =====================================================================================

extension ExportWorker {
    // MARK: - Title card (AVAssetWriter, 2s black + text)

    /// @param titleText タイトルカードに焼き込む文言（既定は撮影日、自由入力なら改行を含む複数行もありうる）。
    ///   空行は詰めて無視する（Android: writeTitleTextFilesと同じ方針）。
    func createTitleCard(titleText: String) async throws -> URL {
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

        let titleLines = VlogLayout.captionLines(titleText).filter { !$0.isEmpty }
        do {
            for frameIdx in 0..<totalFrames {
                try Task.checkCancellation()
                try await waitUntilReady(input)
                let t = CMTime(value: CMTimeValue(frameIdx), timescale: fps)
                if let buffer = renderTitleFrame(size: size, frame: frameIdx, total: totalFrames, titleLines: titleLines) {
                    adaptor.append(buffer, withPresentationTime: t)
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            if let err = writer.error { throw err }
            return url
        } catch {
            // 中止・失敗したら書き込みを畳んで書きかけを消す（ExportWorker.renderClipVideoWithTextと同じ方針）
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
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
        // SFX合成はベストエフォート（失敗しても書き出し全体は止めず、映像のみのvideoURLを返す）。
        // このファイル内の他の失敗パス（sfxURLが見つからない等）と同じ方針。
        guard let compVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return videoURL
        }
        let videoDuration = try await videoAsset.load(.duration)
        try compVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoTrack, at: .zero)

        let delaySeconds = Double(VlogLayout.titleSfxFrameNumber - 1) / 30.0
        let delayTime    = CMTime(seconds: delaySeconds, preferredTimescale: 600)
        let remaining    = videoDuration - delayTime
        if remaining > .zero {
            let sfxDuration  = try await sfxAsset.load(.duration)
            let clippedRange = CMTimeRange(start: .zero, duration: min(sfxDuration, remaining))
            guard let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return videoURL
            }
            try compAudio.insertTimeRange(clippedRange, of: sfxTrack, at: delayTime)
        }

        let outURL = tempURL("title_with_sfx")
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return videoURL
        }
        do {
            try await session.export(to: outURL, as: .mov)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            throw error
        }
        return outURL
    }
}
