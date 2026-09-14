import AVFoundation
import UIKit

// MARK: - ExportManager: テキスト焼き込み描画

/// タイトルカード・キャプションのCGContext描画処理をまとめたもの。ExportManager本体
/// （書き出しパイプラインの制御）から、描画の詳細を分離して見通しを良くする。
extension ExportManager {
    func renderTitleFrame(size: CGSize, frame: Int, total: Int, dateText: String) -> CVPixelBuffer? {
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

    func drawCaptionOverlay(
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
        // PreviewViewのhitokoroOverlayと同じ計算をVlogLayout.hitokotoBlockTopに共通化している
        let topY  = VlogLayout.hitokotoBlockTop(
            lineCount: lines.count, canvasHeight: canvas.height,
            fontSize: VlogLayout.hitokoroFontSize, lineGap: VlogLayout.hitokoroLineGap
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
