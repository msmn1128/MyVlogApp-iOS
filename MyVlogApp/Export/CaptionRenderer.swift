import CoreText
import UIKit

/// ひとことと、タイトルカードの文言を描く。プレビュー（PreviewView）と書き出し（ExportWorker）の
/// 両方がここを通るので、画面と動画で文字の位置・大きさ・絵文字の出方が必ず一致する。
///
/// 縦位置はベースラインで決める（Android: textStripLayout / baselineY）。行の高さ（文字の中身）から
/// 中央を出すと、絵文字や、主のフォント（LogoTypeGothic）に無い字を他のフォントで補った行は
/// 背が高くなり、行ごと・区間ごとに上下へずれていた。ベースラインは主のフォントの ascender /
/// descender だけから決めるので、中身によらず同じ位置に並ぶ（主のフォントだけの行は以前と同じ位置）。
///
/// 描くのはCoreText（CTLine）。無い字は端末のフォントで補われ、絵文字もカラーで描かれる。
/// 渡すCGContextは、UIKitやSwiftUIのCanvasと同じ「左上原点・下向きがy」の座標であること。
///
/// 可変状態を持たないので、どのactorからでも呼べるようnonisolatedにしてある（書き出しはExportWorker上）。
nonisolated enum CaptionRenderer {

    /// ひとこと（上下左右中央、複数行。長い行は折り返す）。空の行・空白だけの行は描かずに位置だけ残す
    /// （Android: hitokotoLines が isBlank の行を描かないのと同じ）
    ///
    /// - Parameter scale: キャンバス（1920x1080）に対する倍率。書き出しは1、プレビューは表示の大きさ÷1080
    static func drawHitokoto(_ text: String, canvas: CGSize, scale: CGFloat, in context: CGContext) {
        let fontSize = VlogLayout.hitokotoFontSize * scale
        let lineGap  = VlogLayout.hitokotoLineGap * scale
        let lineHeight = fontSize + lineGap
        let lines = wrappedHitokotoLines(text)
        let top = VlogLayout.hitokotoBlockTop(
            lineCount: lines.count, canvasHeight: canvas.height, fontSize: fontSize, lineGap: lineGap
        )
        let font = hitokotoFont(size: fontSize)
        for (index, line) in lines.enumerated() {
            drawLine(
                line, font: font, centerX: canvas.width / 2,
                centerY: top + CGFloat(index) * lineHeight + lineHeight / 2, in: context
            )
        }
    }

    /// ひとことの行。改行で分けたうえで、撮影時刻に届かない幅（`VlogLayout.hitokotoWrapWidth`）に
    /// 収まるよう折り返す。空の行・空白だけの行はそのまま1行として残す。
    ///
    /// 測るのは常にキャンバス上の大きさ（倍率1）。表示の倍率で測ると、プレビューの大きさによって
    /// 改行の位置が1文字ずれうる（CoreTextの字の幅は倍率にぴったり比例するとは限らない）。
    /// 倍率1で分けた行を、それぞれの倍率で描くので、プレビューと書き出しの改行位置は必ず一致する
    /// （Android: wrapLines をプレビューと書き出しで共用しているのと同じ）
    static func wrappedHitokotoLines(_ text: String) -> [String] {
        let font = hitokotoFont(size: VlogLayout.hitokotoFontSize)
        return VlogLayout.captionLines(text).flatMap {
            wrap($0, font: font, width: VlogLayout.hitokotoWrapWidth)
        }
    }

    /// 1行を[width]に収まるよう分ける。分け方はCoreText（CTTypesetter）に任せる
    /// （和文の禁則・英単語の区切り・絵文字の組み合わせを守る）。折り返した位置の空白は行末に
    /// 残るので落とす（中央揃えで、その分だけ左へずれて見えるため）
    static func wrap(_ line: String, font: UIFont, width: CGFloat) -> [String] {
        guard !isBlank(line) else { return [line] }
        let typesetter = CTTypesetterCreateWithAttributedString(
            NSAttributedString(string: line, attributes: [.font: font])
        )
        let utf16 = line as NSString
        var pieces: [String] = []
        var start = 0
        while start < utf16.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            guard count > 0 else { break }
            var piece = utf16.substring(with: NSRange(location: start, length: count))
            while let last = piece.last, last.isWhitespace { piece.removeLast() }
            if !piece.isEmpty { pieces.append(piece) }
            start += count
        }
        return pieces.isEmpty ? [line] : pieces
    }

    /// タイトルカードの文言（撮影日または自由入力）。2行目以降になっても1行目の位置は動かさず、
    /// 下へ積む（Android: LineAnchor.TOP）。空白だけの行は詰める（Android: titleLines）
    static func drawTitleLines(_ lines: [String], canvas: CGSize, in context: CGContext) {
        let font = UIFont(name: VlogFonts.timeFontName, size: VlogLayout.titleDateFontSize)
            ?? UIFont.systemFont(ofSize: VlogLayout.titleDateFontSize, weight: .light)
        let lineHeight = VlogLayout.titleDateFontSize + VlogLayout.titleDateLineSpacing
        for (index, line) in lines.enumerated() {
            drawLine(
                line, font: font, centerX: canvas.width / 2,
                centerY: canvas.height / 2 + VlogLayout.titleDateYOffset + CGFloat(index) * lineHeight,
                in: context
            )
        }
    }

    /// タイトルカードの「Vlog.」
    static func drawTitleLogo(canvas: CGSize, in context: CGContext) {
        let font = UIFont(name: VlogFonts.logoTypeName, size: VlogLayout.titleVlogFontSize)
            ?? UIFont.systemFont(ofSize: VlogLayout.titleVlogFontSize, weight: .regular)
        drawLine(
            "Vlog.", font: font, centerX: canvas.width / 2,
            centerY: canvas.height / 2 + VlogLayout.titleVlogYOffset, in: context
        )
    }

    /// タイトルの文言の行。空白だけの行は詰める（ひとことと違って区間ごとに出し分けることが無く、
    /// 空行のぶんだけ間隔を空けておく理由が無いため。Android: titleLines）
    static func titleLines(_ text: String) -> [String] {
        VlogLayout.captionLines(text).filter { !isBlank($0) }
    }

    /// 空白だけ（または空）の行か
    static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// ベースラインの位置。行の中心から、主のフォントの ascender と descender の中点だけ下げる。
    /// 中身（絵文字や補った字）の大きさには左右されない
    static func baselineY(centerY: CGFloat, font: UIFont) -> CGFloat {
        centerY + (font.ascender + font.descender) / 2
    }

    static func hitokotoFont(size: CGFloat) -> UIFont {
        UIFont(name: VlogFonts.logoTypeName, size: size) ?? UIFont.boldSystemFont(ofSize: size)
    }

    /// 1行を、横は中央・縦はベースラインで置いて白で描く。長い行（折り返さないタイトルの文言）は左右へ均等にはみ出す
    static func drawLine(_ text: String, font: UIFont, centerX: CGFloat, centerY: CGFloat, in context: CGContext) {
        guard !isBlank(text) else { return }
        // 色は描く先の塗りの色を使う（CoreTextはUIKitの色の指定を読まないため）。絵文字は自分の色で描かれる
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        context.saveGState()
        context.setFillColor(UIColor.white.cgColor)
        context.textMatrix = .identity
        // CoreTextは上向きがyの座標で描くので、ベースラインへ移してから上下を反転する
        context.translateBy(x: centerX - width / 2, y: baselineY(centerY: centerY, font: font))
        context.scaleBy(x: 1, y: -1)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
