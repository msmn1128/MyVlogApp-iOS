import AVFoundation
import UIKit

// MARK: - ExportManager: テキスト焼き込み描画

/// タイトルカード・キャプションのCGContext描画処理をまとめたもの。ExportWorker本体
/// （書き出しパイプラインの重い処理）から、描画の詳細を分離して見通しを良くする。
extension ExportWorker {
    func renderTitleFrame(size: CGSize, frame: Int, total: Int, titleLines: [String]) -> CVPixelBuffer? {
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

        // Android VlogExporter.ktのフェードアウト計算と一致させる（FADE_START_FRAME/FADE_FRAME_COUNT）。
        // frame=30(0始まり)でalpha=0.95、frame=49でalpha=0.0になるのが正。
        let fadeStart = VlogLayout.titleFadeStartFrame
        let fadeFrameCount = VlogLayout.titleFadeFrameCount
        let fadeEnd = fadeStart + fadeFrameCount // 50 (exclusive)
        let alpha: CGFloat = frame < fadeStart ? 1.0
            : frame >= fadeEnd ? 0.0
            : 1.0 - CGFloat(frame - fadeStart + 1) / CGFloat(fadeFrameCount)

        // 倍率は1にする（既定は画面の倍率で、1920x1080のために3倍の大きさの画像を描いてから縮めていた）
        let format = UIGraphicsImageRendererFormat()
        format.scale  = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { rendererContext in
            // Black background
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            guard alpha > 0 else { return }

            // 「Vlog.」（中央から-70pt）と文言（+80pt、複数行は下へ積む）。縦位置はベースラインで
            // 決めるので、自由入力に絵文字が入っても行がずれない（CaptionRenderer）。
            // フェードは文字ごと（絵文字も一緒に）薄くする
            let context = rendererContext.cgContext
            context.setAlpha(alpha)
            CaptionRenderer.drawTitleLogo(canvas: size, in: context)
            CaptionRenderer.drawTitleLines(titleLines, canvas: size, in: context)
        }

        if let cgImage = image.cgImage {
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }

        return pb
    }

    /// 1クリップぶんのキャプション画像（ひとこと＋撮影時刻を描いた透明な1920x1080）を、区間ごとに出すもの。
    ///
    /// 描く内容は「その時点のひとこと」と「撮影時刻」だけで、**ひとことの区間内では
    /// どのフレームでも同一**。フレームごとに描き起こすと秒間30回まるごと描き直すことになるので、
    /// 区間ごとに1枚だけ作って使い回す。
    ///
    /// 持つのは、いま使っている区間の1枚だけ。以前は全区間ぶんを書き出しの前にまとめて作っていたが、
    /// 1枚が約8MB（1920x1080の32bit）あり、区間が10なら約80MB、細かく区切った長いクリップでは
    /// 数百MBを抱えていた（Android が全画面ではなく帯の画像にしているのも同じ理由）。
    /// コマは時間の順に読むので、区間が変わったときに描き直すだけで済む。
    nonisolated struct CaptionOverlays {
        fileprivate let canvas: CGSize
        fileprivate let spans: [(spanStart: Int64, spanEnd: Int64, text: String)]
        fileprivate let timeText: String
        /// いま持っている画像がどの区間のものか（nil＝区間の隙間で使う、撮影時刻だけの画像）。
        /// 外側のOptionalがnilなら、まだ何も作っていない
        private var cachedSpan: Int?? = .none
        private var cachedImage: CGImage?

        init(canvas: CGSize, spans: [(spanStart: Int64, spanEnd: Int64, text: String)], timeText: String) {
            self.canvas = canvas
            self.spans = spans
            self.timeText = timeText
        }

        /// `positionMs`（トリム開始からの位置）に重ねる画像。区間が変わったときだけ描き直す
        fileprivate mutating func image(at positionMs: Int64) -> CGImage? {
            let index = spans.firstIndex { positionMs >= $0.spanStart && positionMs < $0.spanEnd }
            if let cachedSpan, cachedSpan == index { return cachedImage }
            let text = index.map { spans[$0].text }
            let (canvas, timeText) = (canvas, timeText)
            cachedImage = ExportWorker.renderOverlay(canvas: canvas) { context in
                if let text { CaptionRenderer.drawHitokoto(text, canvas: canvas, scale: 1, in: context) }
                ExportWorker.drawTimestamp(timeText, canvas: canvas)
            }
            cachedSpan = .some(index)
            return cachedImage
        }
    }

    /// 1クリップぶんのキャプション画像の出し分けを用意する（`renderClipVideoWithText`のループの外で1回）
    func makeCaptionOverlays(
        canvas: CGSize, spans: [(spanStart: Int64, spanEnd: Int64, text: String)], timeText: String
    ) -> CaptionOverlays {
        CaptionOverlays(canvas: canvas, spans: spans, timeText: timeText)
    }

    /// 透明背景のオーバーレイ画像を1枚作る
    fileprivate nonisolated static func renderOverlay(canvas: CGSize, draw: (CGContext) -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale  = 1
        return UIGraphicsImageRenderer(size: canvas, format: format).image { draw($0.cgContext) }.cgImage
    }

    /// 読み取ったフレームを書き込み用のバッファへ写し、その上へキャプションを重ねる。
    ///
    /// 以前は`AVAssetReader`が返してきたバッファを直接書き換え、それをそのまま
    /// `AVAssetWriter`へ渡していた。reader側のバッファは内部のプールから貸し出された
    /// もので、こちらが書き換えてよいとはどこにも保証されていない（AVFoundationが
    /// 再利用したり、内部で参照を持ち続けたりしても文句は言えない）。
    /// writer側のプール（`adaptor.pixelBufferPool`）から借りたバッファへ写してから描くことで、
    /// 「読み取り側のものには触らない・書き込み側のものだけを書く」形にする。
    ///
    /// 写してから重ねるので、キャプションが無い位置（区間の隙間）でも必ず写しは行う。
    func composeFrame(
        source: CVPixelBuffer, destination: CVPixelBuffer, canvas: CGSize,
        positionMs: Int64, overlays: inout CaptionOverlays
    ) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        copyPixels(from: source, to: destination)

        // この位置に出す1枚（区間が変わったときだけ描き直す）
        guard let overlay = overlays.image(at: positionMs) else { return }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(destination),
            width: Int(canvas.width), height: Int(canvas.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(destination),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return }

        // 写した映像の上へアルファ合成で重ねる
        ctx.draw(overlay, in: CGRect(origin: .zero, size: canvas))
    }

    /// 同じ画素形式（32BGRA）のバッファ同士で中身を写す。
    ///
    /// 1行あたりのバイト数（stride）はバッファごとに違いうる（プールが確保時に
    /// 余白を付けることがある）ので、まとめてmemcpyできるのは stride が一致するときだけ。
    /// 違うときは行ごとに、短いほうの長さぶんだけ写す。
    private func copyPixels(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        guard let src = CVPixelBufferGetBaseAddress(source),
              let dst = CVPixelBufferGetBaseAddress(destination) else { return }
        let srcStride = CVPixelBufferGetBytesPerRow(source)
        let dstStride = CVPixelBufferGetBytesPerRow(destination)
        let height    = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination))

        if srcStride == dstStride {
            memcpy(dst, src, srcStride * height)
        } else {
            let rowBytes = min(srcStride, dstStride)
            for row in 0..<height {
                memcpy(dst + row * dstStride, src + row * srcStride, rowBytes)
            }
        }
    }

    /// 撮影時刻：上下中央・キャンバス右端基準（Android: TIME_FONT_PT / TIME_MARGIN_PT）
    fileprivate nonisolated static func drawTimestamp(_ text: String, canvas: CGSize) {
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
}
