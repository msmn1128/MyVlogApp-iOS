import CoreGraphics
import CoreText
import Testing
import UIKit
@testable import MyVlogApp

/// ひとこと・タイトルの文言の描き方（CaptionRenderer）。プレビューと書き出しの両方がこれを使う。
/// Android: TextImagesLayoutTest / TextImagesTest
@Suite("文字の描き方")
struct CaptionRendererTests {

    private let canvas = VlogLayout.canvasSize

    /// ひとことを1920x1080の透明な画像に描き、各画素の不透明度（alpha）を返す（添字は y * 幅 + x）
    private func hitokotoAlpha(_ text: String) -> (width: Int, height: Int, alpha: [UInt8]) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image {
            CaptionRenderer.drawHitokoto(text, canvas: canvas, scale: 1, in: $0.cgContext)
        }.cgImage!
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (width, height, stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] })
    }

    /// 白い画素のある行（y）の範囲を、中央の縦長の帯（x=900…1020）の中だけで調べる
    private func inkRows(ofHitokoto text: String) -> ClosedRange<Int>? {
        let (width, height, alpha) = hitokotoAlpha(text)
        var rows: [Int] = []
        for y in 0..<height {
            for x in 900..<1020 where alpha[y * width + x] > 128 {
                rows.append(y)
                break
            }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first...last
    }

    @Test("絵文字が入っても、同じ字は同じ高さに描かれる（行が上下へずれない）")
    func emojiDoesNotShiftTheLine() throws {
        // 回帰テスト: 行の高さ（中身）から中央を出していた頃は、背の高い絵文字が入ると行ごと
        // 上下へずれていた。中央の「あ」の描かれる範囲は、両脇の絵文字の有無によらず同じであること
        let plain = try #require(inkRows(ofHitokoto: "あ"))
        let withEmoji = try #require(inkRows(ofHitokoto: "😀あ😀"))
        #expect(plain == withEmoji, "絵文字なし \(plain) / あり \(withEmoji)")
    }

    @Test("主のフォントだけの1行は、以前のプレビュー（SwiftUIのText）と同じ高さに描かれる")
    func singleLineMatchesThePreviousPreview() throws {
        // 以前のプレビュー（Textを中心に置く）では「あ」は y=510〜569 に描かれていた（シミュレータで実測）。
        // 描き方をまとめても、見た目の位置が変わらないこと
        let rows = try #require(inkRows(ofHitokoto: "あ"))
        #expect(abs(rows.lowerBound - 510) <= 1 && abs(rows.upperBound - 569) <= 1, "字の範囲が \(rows)")
    }

    @Test("空白だけの行は描かない（位置は残す）")
    func blankLinesAreNotDrawn() {
        #expect(inkRows(ofHitokoto: "   ") == nil)
        #expect(inkRows(ofHitokoto: " \n\u{3000}") == nil)
    }

    @Test("タイトルの文言は、空の行と空白だけの行を詰める")
    func titleLinesSkipBlankLines() {
        #expect(CaptionRenderer.titleLines("旅行\n \n\r\n2日目") == ["旅行", "2日目"])
    }

    @Test("ベースラインは主のフォントの寸法だけで決まる")
    func baselineDependsOnlyOnTheFont() {
        let font = CaptionRenderer.hitokotoFont(size: 70)
        let baseline = CaptionRenderer.baselineY(centerY: 540, font: font)
        #expect(baseline == 540 + (font.ascender + font.descender) / 2)
        // 行の中心より下（ベースラインの下には、下に伸びる字のぶんがある）
        #expect(baseline > 540)
    }

    // MARK: - 自動の折り返し

    private let longHitokoto = "今日は朝から海へ行って、みんなでバーベキューをしてから花火を見ました🎆"

    private func lineWidth(_ text: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: CaptionRenderer.hitokotoFont(size: VlogLayout.hitokotoFontSize)]
        ))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    @Test("長いひとことは折り返し幅に収まるよう折り返し、文字を落とさない")
    func longHitokotoIsWrappedWithinTheWidth() {
        let lines = CaptionRenderer.wrappedHitokotoLines(longHitokoto)

        #expect(lines.count >= 2, "\(lines)")
        for line in lines {
            #expect(lineWidth(line) <= VlogLayout.hitokotoWrapWidth, "\(line) の幅 \(lineWidth(line))")
        }
        // 折り返しで文字が消えたり増えたりしない（絵文字も割れない）
        #expect(lines.joined() == longHitokoto)
    }

    @Test("短い行と空の行は、そのまま残す")
    func shortAndBlankLinesAreKept() {
        #expect(CaptionRenderer.wrappedHitokotoLines("上\n\n下") == ["上", "", "下"])
        #expect(CaptionRenderer.wrappedHitokotoLines("") == [""])
    }

    @Test("折り返したひとことは、右端の撮影時刻の側へはみ出さない")
    func wrappedHitokotoStaysClearOfTheShootingTime() {
        // 左右に(1920-折り返し幅)/2ずつ空く（数pxは文字のにじみの余裕）
        let (width, height, alpha) = hitokotoAlpha(longHitokoto)
        let side = Int((VlogLayout.canvasWidth - VlogLayout.hitokotoWrapWidth) / 2) - 4
        var outside = 0
        for y in 0..<height {
            for x in Array(0..<side) + Array((width - side)..<width) where alpha[y * width + x] > 0 {
                outside += 1
            }
        }
        #expect(outside == 0)
    }
}
