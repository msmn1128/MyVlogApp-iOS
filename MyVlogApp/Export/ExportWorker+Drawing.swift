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

            // Line 2以降: タイトル文言（既定は撮影日、自由入力なら複数行もありうる）。
            // Android: TITLE_DATE_FONT_PT / TITLE_DATE_Y_OFFSET_PT、+80ptずらす。
            // 複数行になっても1行目の位置（titleDateYOffset）は動かさず、以降を
            // titleDateLineSpacingぶんの行送りで下へ積む（Android: LineAnchor.TOP）。
            let dateFont = UIFont(name: VlogFonts.timeFontName, size: VlogLayout.titleDateFontSize)
                ?? UIFont.systemFont(ofSize: VlogLayout.titleDateFontSize, weight: .light)
            let dateAttrs: [NSAttributedString.Key: Any] = [
                .font:            dateFont,
                .foregroundColor: UIColor.white.withAlphaComponent(alpha)
            ]
            let lineHeight = VlogLayout.titleDateFontSize + VlogLayout.titleDateLineSpacing

            // Android centeredY(offsetPt) = (h-text_h)/2 + offsetPt をそのまま踏襲
            let vlogY = (size.height - vlogSize.height) / 2 + VlogLayout.titleVlogYOffset
            vlogStr.draw(in: CGRect(
                x: (size.width - vlogSize.width) / 2,
                y: vlogY,
                width: vlogSize.width,
                height: vlogSize.height
            ))

            for (idx, line) in titleLines.enumerated() {
                let lineStr = NSAttributedString(string: line, attributes: dateAttrs)
                let lineSize = lineStr.size()
                let lineY = (size.height - lineSize.height) / 2
                    + VlogLayout.titleDateYOffset + CGFloat(idx) * lineHeight
                lineStr.draw(in: CGRect(
                    x: (size.width - lineSize.width) / 2,
                    y: lineY,
                    width: lineSize.width,
                    height: lineSize.height
                ))
            }
        }

        if let cgImage = image.cgImage {
            ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }

        return pb
    }

    /// 1クリップぶんのキャプション画像をあらかじめ作っておくもの。
    ///
    /// 描く内容は「その時点のひとこと」と「撮影時刻」だけで、**ひとことの区間内では
    /// どのフレームでも同一**。以前はフレームごとに`UIGraphicsImageRenderer`を作って
    /// 1920x1080を描き起こしており、30fpsのクリップでは秒間30回まるごと描き直していた。
    /// 区間ごとに1枚だけ作って使い回す（10秒のクリップなら300回 → 区間数ぶんに減る）。
    struct CaptionOverlays {
        /// 区間の添字 → その区間で重ねる画像。ひとことが空の区間はnil（時刻だけの画像を使う）
        fileprivate let bySpan: [CGImage?]
        /// どの区間にも当たらない位置（区間の隙間）で使う、撮影時刻だけの画像
        fileprivate let timeOnly: CGImage?
        fileprivate let spans: [(spanStart: Int64, spanEnd: Int64, text: String)]
    }

    /// クリップの全区間ぶんのキャプション画像を先に作る（`renderClipVideoWithText`のループの外で1回）
    func makeCaptionOverlays(
        canvas: CGSize, spans: [(spanStart: Int64, spanEnd: Int64, text: String)], timeText: String
    ) -> CaptionOverlays {
        CaptionOverlays(
            bySpan: spans.map { span in
                renderOverlay(canvas: canvas) {
                    drawHitokoto(span.text, canvas: canvas)
                    drawTimestamp(timeText, canvas: canvas)
                }
            },
            timeOnly: renderOverlay(canvas: canvas) { drawTimestamp(timeText, canvas: canvas) },
            spans: spans
        )
    }

    /// 透明背景のオーバーレイ画像を1枚作る
    private func renderOverlay(canvas: CGSize, draw: () -> Void) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale  = 1
        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in draw() }.cgImage
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
        positionMs: Int64, overlays: CaptionOverlays
    ) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }

        copyPixels(from: source, to: destination)

        // 作り置きの中から、この位置に出す1枚を選ぶだけ
        let index = overlays.spans.firstIndex { positionMs >= $0.spanStart && positionMs < $0.spanEnd }
        guard let overlay = index.map({ overlays.bySpan[$0] }) ?? overlays.timeOnly else { return }

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

    /// 「ひとこと」：上下左右中央、複数行対応（Android: HITOKOTO_FONT_PT / LINE_SPACING）
    private func drawHitokoto(_ text: String, canvas: CGSize) {
        let font = UIFont(name: VlogFonts.logoTypeName, size: VlogLayout.hitokotoFontSize)
            ?? UIFont.boldSystemFont(ofSize: VlogLayout.hitokotoFontSize)
        let lineH = VlogLayout.hitokotoFontSize + VlogLayout.hitokotoLineGap
        let lines = VlogLayout.captionLines(text)
        // PreviewViewのhitokotoOverlayと同じ計算をVlogLayout.hitokotoBlockTopに共通化している
        let topY  = VlogLayout.hitokotoBlockTop(
            lineCount: lines.count, canvasHeight: canvas.height,
            fontSize: VlogLayout.hitokotoFontSize, lineGap: VlogLayout.hitokotoLineGap
        )

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
}
