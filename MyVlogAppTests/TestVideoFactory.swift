import AVFoundation
import CoreGraphics
import Foundation
import UIKit

// =====================================================================================
// 書き出しの結合テスト（ExportOutputTests）用に、短い単色の動画をその場で作るヘルパーと、
// 書き出した動画のフレームを取り出してピクセルを調べるヘルパー。
//
// 書き出しは「実際に動画を1本通してみないと結果が分からない」処理で、これまで
// UIテストは「始まる・進捗が出る・中止できる」までしか見ていなかった。焼き込んだ文字が
// 正しい位置に出ているかは、出力フレームのピクセルを直接見るのがいちばん確実なので、
// そのための最小限の道具をここへ置く。
// =====================================================================================

/// 書き出し（ExportWorker）を、アプリが実際に走らせるのと同じ優先度（utility）で実行する。
///
/// ExportWorkerの中心は`AVAssetReader.copyNextSampleBuffer()`という同期呼び出しで、
/// AVFoundation内部のデコードスレッド（utility）を待つ。アプリ側はこれを
/// `Task(priority: .utility)`で起こし、その結果を誰も待たない（exportTaskは中止用に
/// 持っているだけ）ので、最後までutilityのまま走る。
///
/// 一方テストは結果を待つ必要がある。ここで`Task(priority: .utility) { ... }.value`と
/// 書くと、Swiftの優先度昇格で待つ側（テスト＝user-initiated）の優先度へ引き上げられ、
/// 本番と違う条件になってしまう。実際その形だと
/// 「User-initiatedのスレッドがUtilityのスレッドを待っている」という優先度逆転が起きる
/// （Thread Performance Checkerが報告する）。
///
/// 継続（continuation）で結果を受け渡すと昇格が伝わらないので、本番と同じく
/// utilityのまま最後まで走る。テストを本番の条件へ寄せるための仕掛けであって、
/// 警告を黙らせるためのごまかしではない。
///
/// 切り離したタスクには中止が伝わらないので、待つ側が中止されたら手で伝える（中止のテストのため）
nonisolated func runAtExportPriority<T: Sendable>(
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let handle = DetachedHandle()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            handle.set(Task.detached(priority: .utility) {
                do { continuation.resume(returning: try await body()) }
                catch { continuation.resume(throwing: error) }
            })
        }
    } onCancel: {
        handle.cancel()
    }
}

/// 切り離したタスクへ中止を伝えるための入れ物。タスクを作る前に中止されることもあるので、それも覚えておく
private nonisolated final class DetachedHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ task: Task<Void, Never>) {
        lock.lock(); defer { lock.unlock() }
        self.task = task
        if cancelled { task.cancel() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

/// 可変状態を持たないヘルパーなので、プロジェクト全体の既定（MainActor）から外す。
/// 外さないと、テスト用の動画生成（AVAssetWriterのエンコードループ）が
/// メインスレッドで走ってしまう
nonisolated enum TestVideoFactory {

    /// テスト用の短い単色動画（無音）を一時ディレクトリへ作る。
    ///
    /// 暗い色にしてあるのは、書き出しで焼き込まれる白い文字を輝度だけで見分けられるようにするため。
    /// 4:3にしてあるのは、16:9のキャンバスへ収めたときに左右へ黒帯ができ、
    /// 「文字が無いはずの場所」（＝対照に使える領域）が確実にできるようにするため。
    ///
    /// - Returns: 作った動画のURL。後始末は呼び出し側（`remove(_:)`）が行う
    static func makeSolidColorVideo(
        seconds: Double = 1,
        size: CGSize = CGSize(width: 320, height: 240),
        fps: Int32 = 30,
        color: UIColor = UIColor(white: 0.12, alpha: 1),
        colorProperties: [String: String]? = nil,
        transform: CGAffineTransform = .identity
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporttest_\(UUID().uuidString).mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey:  AVVideoCodecType.h264,
                AVVideoWidthKey:  Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ].merging(colorProperties.map { [AVVideoColorPropertiesKey: $0] } ?? [:]) { $1 }
        )
        input.expectsMediaDataInRealTime = false
        // 縦向きで撮った動画のように、画素は横長のまま「回して見せる」情報だけを付ける
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:  Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TestVideoError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            guard let pool = adaptor.pixelBufferPool else { throw TestVideoError.writerFailed }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { throw TestVideoError.writerFailed }
            fill(buffer, with: color)
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestVideoError.writerFailed }
        return url
    }

    /// 映像と長さの違う音声（440Hzの音）を持つ動画を作る。音声の長さだけを映像とずらしたいときに使う
    /// （素材の音声は映像より数十ms短いことがあり、その扱いを確かめるため）。
    static func makeVideoWithAudio(
        videoSeconds: Double, audioSeconds: Double, sampleRate: Double = 44_100
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("exporttest_audio_\(UUID().uuidString).mov")
        let size = CGSize(width: 320, height: 240)
        let fps: Int32 = 30

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width), kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000
        ])
        video.expectsMediaDataInRealTime = false
        audio.expectsMediaDataInRealTime = false
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? TestVideoError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<Int(videoSeconds * Double(fps)) {
            while !video.isReadyForMoreMediaData { await Task.yield() }
            guard let pool = adaptor.pixelBufferPool else { throw TestVideoError.writerFailed }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { throw TestVideoError.writerFailed }
            fill(buffer, with: UIColor(white: 0.12, alpha: 1))
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        }
        video.markAsFinished()

        // 1024サンプルずつ、16bitのPCMで渡す（AACへはwriterが変換する）
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0
        )
        var formatDescription: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription
        )
        let totalFrames = Int(audioSeconds * sampleRate)
        var written = 0
        while written < totalFrames {
            while !audio.isReadyForMoreMediaData { await Task.yield() }
            let count = min(1024, totalFrames - written)
            var samples = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                samples[i] = Int16(sin(2 * .pi * 440 * Double(written + i) / sampleRate) * 12_000)
            }
            var block: CMBlockBuffer?
            let bytes = count * 2
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
            )
            guard let block else { throw TestVideoError.writerFailed }
            samples.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
            }
            var sampleBuffer: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: formatDescription!,
                sampleCount: count, presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sampleBuffer
            )
            guard let sampleBuffer else { throw TestVideoError.writerFailed }
            audio.append(sampleBuffer)
            written += count
        }
        audio.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? TestVideoError.writerFailed }
        return url
    }

    /// 音声が最初に鳴り始める時刻（秒）。50msごとの音量が`threshold`を超えた最初の区間の頭。鳴らなければnil
    static func audioOnsetSeconds(of url: URL, threshold: Float = 0.05) async throws -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let sampleRate = 8_000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false
        ])
        reader.add(output)
        reader.startReading()
        var samples: [Int16] = []
        var firstTime: Double?
        while let buffer = output.copyNextSampleBuffer() {
            if firstTime == nil { firstTime = CMSampleBufferGetPresentationTimeStamp(buffer).seconds }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &chunk)
            samples += chunk
        }
        let window = Int(sampleRate * 0.05)
        var start = 0
        while start + window <= samples.count {
            let rms = sqrt(samples[start..<(start + window)].reduce(Float(0)) { $0 + Float($1) * Float($1) } / Float(window)) / 32768
            if rms > threshold { return (firstTime ?? 0) + Double(start) / sampleRate }
            start += window
        }
        return nil
    }

    /// 動画の各トラックの長さ（秒）
    static func trackSeconds(of url: URL) async throws -> (video: Double, audio: Double?) {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let videoRange = try await video?.load(.timeRange)
        let audioRange = try await audio?.load(.timeRange)
        return (videoRange?.end.seconds ?? 0, audioRange?.end.seconds)
    }

    /// HLG（HDR）の印を付けた動画を作るときの色の設定。中身の画素は同じまま、印だけが変わる
    static let hlgColorProperties: [String: String] = [
        AVVideoColorPrimariesKey:     AVVideoColorPrimaries_ITU_R_2020,
        AVVideoTransferFunctionKey:   AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoYCbCrMatrixKey:        AVVideoYCbCrMatrix_ITU_R_2020
    ]

    static func remove(_ urls: URL?...) {
        for url in urls.compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func fill(_ buffer: CVPixelBuffer, with color: UIColor) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base,
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return }
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    }
}

enum TestVideoError: Error {
    case writerFailed
    case noVideoTrack
}

// MARK: - 書き出した動画の中身を調べる

/// こちらもTestVideoFactoryと同じ理由でnonisolated
/// （1920x1080のピクセル走査をメインスレッドでやらせない）
nonisolated enum FrameInspector {

    /// 動画の指定時刻のフレームを取り出す（前後にずれないよう許容誤差は0にする）
    static func frame(of url: URL, atSeconds seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter  = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    static func durationSeconds(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    /// 映像トラックの、向きを反映した表示サイズ
    static func displaySize(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw TestVideoError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let transform   = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
    }

    static func hasAudioTrack(_ url: URL) async throws -> Bool {
        try await !AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty
    }

    /// `rect`（左上原点）の中で、条件に合う画素の数（RGBは0〜255）
    static func pixelCount(_ image: CGImage, in rect: CGRect, where matches: (Int, Int, Int) -> Bool) -> Int {
        let width  = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let minX = max(0, Int(rect.minX)), maxX = min(width,  Int(rect.maxX))
        let minY = max(0, Int(rect.minY)), maxY = min(height, Int(rect.maxY))
        guard minX < maxX, minY < maxY else { return 0 }
        var count = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let i = (y * width + x) * 4
                if matches(Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2])) { count += 1 }
            }
        }
        return count
    }

    /// `rect`（左上原点）の中の、RGBそれぞれの平均（0〜255）
    static func meanRGB(_ image: CGImage, in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        let width  = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let minX = max(0, Int(rect.minX)), maxX = min(width,  Int(rect.maxX))
        let minY = max(0, Int(rect.minY)), maxY = min(height, Int(rect.maxY))
        guard minX < maxX, minY < maxY else { return (0, 0, 0) }
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        for y in minY..<maxY {
            for x in minX..<maxX {
                let i = (y * width + x) * 4
                sum.r += Double(pixels[i]); sum.g += Double(pixels[i + 1]); sum.b += Double(pixels[i + 2])
            }
        }
        let n = Double((maxX - minX) * (maxY - minY))
        return (sum.r / n, sum.g / n, sum.b / n)
    }

    /// `rect`（左上原点）の中で、明るいピクセルがいくつあるか。
    ///
    /// 焼き込まれる文字は白なので、元動画を暗い色にしておけば輝度だけで
    /// 「そこに文字が描かれているか」を判定できる。
    static func brightPixelCount(_ image: CGImage, in rect: CGRect, threshold: Int = 180) -> Int {
        let width  = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(
            data: &pixels,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // CGBitmapContextのメモリは先頭行が画像の上端なので、rectは左上原点で解釈できる
        let minX = max(0, Int(rect.minX)), maxX = min(width,  Int(rect.maxX))
        let minY = max(0, Int(rect.minY)), maxY = min(height, Int(rect.maxY))
        guard minX < maxX, minY < maxY else { return 0 }

        var count = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                let i = (y * width + x) * 4
                // 白い文字を拾うだけなので、RGBすべてが明るいかどうかで十分
                if Int(pixels[i]) > threshold, Int(pixels[i + 1]) > threshold, Int(pixels[i + 2]) > threshold {
                    count += 1
                }
            }
        }
        return count
    }
}
