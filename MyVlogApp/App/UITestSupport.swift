import Foundation

// =====================================================================================
// アプリの保存先の決定。
//
// 通常は UserDefaults.standard。UIテスト実行時だけ使い捨ての領域に切り替えて、
// シミュレータに残っている実際の編集内容を壊さず、毎回同じ初期状態から始められるようにする。
// =====================================================================================

enum AppEnvironment {
    /// VlogStoreの保存先。起動ごとに1回だけ決まる
    static let defaults: UserDefaults = {
        #if DEBUG
        if let disposable = UITestSupport.disposableDefaults() { return disposable }
        #endif
        return .standard
    }()
}

#if DEBUG
import AVFoundation
import CoreGraphics
import UIKit

// =====================================================================================
// UIテスト専用の仕込み。
//
// 再生と書き出しはタイムラインに実体のある動画が無いと動かないが、動画の取り込みは
// システムのフォトピッカー（別プロセス）を通るためXCUITestからは操作できない
// （MyVlogAppUITests.swift の既存コメント参照）。そこで、起動引数が渡されたときだけ
// アプリ自身がテスト用の短い動画を作ってタイムラインへ入れる。
//
// 投入は VlogStore.addClips をそのまま通すので、追加の重複判定・上限・撮影日時順の
// 差し込みといった実際の経路は迂回しない。
//
// DEBUGビルドにしか入らないため、リリースビルドにこのコードは含まれない。
// =====================================================================================

enum UITestSupport {
    /// 「テスト用の動画をN本入れて起動する」起動引数（例: -UITestSeedClips 2）
    private static let seedArgument = "-UITestSeedClips"

    /// テスト用の動画1本の長さ（秒）を変える起動引数（例: -UITestSeedClipSeconds 4）。
    /// 既定は短め。トリムのテストのように「切った長さと元の長さの違い」を見たいときだけ長くする
    private static let secondsArgument = "-UITestSeedClipSeconds"

    /// 使い捨ての保存領域を、起動時に空にしないで使う起動引数。前回の起動で保存した内容から
    /// 始めたいテスト（前回の続きの復元）で、`-UITestSeedClips 0`と一緒に渡す
    private static let keepSavedStateArgument = "-UITestKeepSavedState"

    /// 起動引数が1つでもあれば、保存先を使い捨てにする目印として使う
    private static var isUITestRun: Bool {
        ProcessInfo.processInfo.arguments.contains(seedArgument)
    }

    /// UIテストで動いているか。
    ///
    /// 通知の許可ダイアログのように、OSがアプリの上に出してくる割り込みは
    /// XCUITestの操作を遮ってテストを不安定にする。そういうものを出さないための
    /// 判断に使う（`AppEnvironment`が保存先を切り替えているのと同じ目印・同じ考え方）。
    /// DEBUGビルドにしか無いので、リリースビルドの挙動には一切影響しない。
    static var isRunningUITests: Bool { isUITestRun }

    /// 入れるクリップの本数。指定が無ければnil
    static var seedClipCount: Int? {
        value(after: seedArgument).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    /// 入れるクリップ1本の長さ（秒）。指定が無ければ2秒
    /// （再生のテストが待たされないよう短くしてある）
    static var seedClipSeconds: Double {
        value(after: secondsArgument).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 2
    }

    /// 起動引数`name`の次に置かれた値を取り出す
    private static func value(after name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// UIテスト実行時だけ、起動のたびに空になる保存領域を返す。通常起動ではnil
    static func disposableDefaults() -> UserDefaults? {
        guard isUITestRun else { return nil }
        let name = "com.masamune.myvlogapp.uitest"
        // 前回のテスト実行が残した内容を消してから始める（前回の続きを確かめるテストでは残す）
        if !ProcessInfo.processInfo.arguments.contains(keepSavedStateArgument) {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        return UserDefaults(suiteName: name)
    }

    /// 起動引数で指定された本数のテスト用クリップをタイムラインへ入れる。
    /// 指定が無ければ何もしないので、通常起動では呼んでも副作用がない。
    @MainActor
    static func seedClipsIfRequested(into store: VlogStore) async {
        guard let count = seedClipCount else { return }

        let seconds = seedClipSeconds
        var clips: [VlogClip] = []
        for index in 0..<count {
            guard let url = await makeTestVideo(index: index, durationSeconds: seconds) else { continue }
            // 実際の取り込みと同じ読み取り経路を通す
            guard let meta = await VideoMetadataReader.readFile(
                at: url, originalFileName: url.lastPathComponent, fallbackDate: Date()
            ) else { continue }

            clips.append(
                VlogClip.imported(
                    fileURL: url,
                    relativeFilePath: url.lastPathComponent,
                    timeText: meta.timeText,
                    dateText: meta.dateText,
                    durationMs: meta.durationMs,
                    width: meta.width,
                    height: meta.height,
                    // 並び順をテストから予測できるよう、撮影時刻は投入順に1分ずつずらす
                    shotAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60)),
                    shotAtReliable: true
                )
            )
        }
        store.addClips(clips)
    }

    /// テスト用の短い動画（無音・単色）をDocumentsへ作る。
    /// 小さめの解像度にしてあるのは、書き出しのテストで待たされないようにするため
    /// （書き出しはどのみち1920x1080へスケールするので、入力サイズは結果に影響しない）。
    private static func makeTestVideo(
        index: Int, durationSeconds: Double = 2, fps: Int32 = 30
    ) async -> URL? {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = documents.appendingPathComponent("uitest_clip_\(index).mov")
        try? FileManager.default.removeItem(at: url)

        let size = CGSize(width: 320, height: 240)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey:  AVVideoCodecType.h264,
                AVVideoWidthKey:  Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String:  Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(durationSeconds * Double(fps))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData { await Task.yield() }
            guard let pool = adaptor.pixelBufferPool else { break }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            guard let buffer = pixelBuffer else { break }

            // クリップごとに色を変えて、どのクリップが映っているかスクリーンショットで分かるようにする
            fill(buffer, hue: CGFloat(index) * 0.25)
            adaptor.append(
                buffer,
                withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)
            )
        }

        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }

    private static func fill(_ buffer: CVPixelBuffer, hue: CGFloat) {
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

        context.setFillColor(UIColor(hue: hue, saturation: 0.7, brightness: 0.8, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
    }
}
#endif
