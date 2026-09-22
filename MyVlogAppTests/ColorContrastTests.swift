import SwiftUI
import Testing
import UIKit
@testable import MyVlogApp

// =====================================================================================
// 配色のコントラスト比（WCAG 2.1）。
//
// AppColorsはAndroid版のMaterial3パレットの移植で、概ね妥当な値ではあるが、
// 「誰も測っていない」状態だった。色を1つ足したり差し替えたりしたときに
// 気付けるよう、実際に比を計算して基準を割っていないことをここで守る。
//
// 基準（SC 1.4.3 / 1.4.11）:
//   - 通常の文字        4.5:1
//   - 大きい文字        3:1（18pt以上、または14pt以上の太字）
//   - UI部品の輪郭・状態 3:1
//
// 対象外:
//   - 無効状態の文字（opacity 0.38）。SC 1.4.3が明示的に除外している
//     （"inactive user interface component" は要件の対象外）
//   - 区切り線などの純粋な装飾（AppColors.outlineVariant）
//   - サムネイル画像の上に乗る文字。背景が動画そのもので測りようがないため、
//     影（.shadow）と黒のグラデーションで可読性を確保している
// =====================================================================================

@MainActor
@Suite("配色のコントラスト比")
struct ColorContrastTests {

    /// 画面のどの組み合わせを見るか（説明, 前景, 背景, 必要な比）
    private struct Pair {
        let label: String
        let foreground: (ColorScheme) -> Color
        let background: (ColorScheme) -> Color
        let required: Double
    }

    private var pairs: [Pair] {
        [
            Pair(label: "見出し・ラベル on カード",
                 foreground: AppColors.onSurfaceVariant, background: AppColors.card, required: 4.5),
            Pair(label: "ラベル on ダイアログ",
                 foreground: AppColors.onSurfaceVariant, background: AppColors.cardHigh, required: 4.5),
            Pair(label: "ラベル on 背景",
                 foreground: AppColors.onSurfaceVariant, background: AppColors.background, required: 4.5),
            Pair(label: "動画を追加・保存（tonalPill）",
                 foreground: AppColors.onSecondaryContainer, background: AppColors.secondaryContainer, required: 4.5),
            Pair(label: "書き出し（primaryPill）",
                 foreground: AppColors.onPrimary, background: AppColors.primary, required: 4.5),
            Pair(label: "ダイアログの文字ボタン",
                 foreground: AppColors.primary, background: AppColors.cardHigh, required: 4.5),
            Pair(label: "中止（outlinedPill）の文字",
                 foreground: AppColors.primary, background: AppColors.background, required: 4.5),
            Pair(label: "区間バッジの数字",
                 foreground: AppColors.onSplitLine, background: AppColors.splitLine, required: 4.5),
            // ここから下はUI部品・アイコン（3:1）
            Pair(label: "トグルONのアイコン",
                 foreground: AppColors.onPrimaryContainer, background: AppColors.primaryContainer, required: 3),
            Pair(label: "削除アイコン",
                 foreground: AppColors.error, background: AppColors.card, required: 3),
            Pair(label: "再生ヘッド",
                 foreground: AppColors.tertiary, background: AppColors.card, required: 3),
            Pair(label: "入力欄・ボタンの輪郭 on ダイアログ",
                 foreground: AppColors.outline, background: AppColors.cardHigh, required: 3),
            Pair(label: "入力欄・ボタンの輪郭 on カード",
                 foreground: AppColors.outline, background: AppColors.card, required: 3),
            Pair(label: "入力欄・ボタンの輪郭 on 背景",
                 foreground: AppColors.outline, background: AppColors.background, required: 3),
        ]
    }

    @Test("ライトモードのすべての組み合わせが基準を満たす")
    func lightScheme() {
        assertAllPairs(in: .light)
    }

    @Test("ダークモードのすべての組み合わせが基準を満たす")
    func darkScheme() {
        assertAllPairs(in: .dark)
    }

    @Test("部品の輪郭は、装飾用の薄い線より確実に濃い")
    func outlineIsStrongerThanDecorativeLine() {
        // 回帰テスト: 入力欄の枠に装飾用のoutlineVariantを使っていたため、
        // ダイアログ背景とのコントラストが1.4:1しかなく、枠がほとんど見えていなかった。
        // 取り違えると同じことが起きるので、濃さの大小関係を明示しておく
        for scheme in [ColorScheme.light, .dark] {
            let outline  = contrast(AppColors.outline(scheme), AppColors.cardHigh(scheme))
            let variant  = contrast(AppColors.outlineVariant(scheme), AppColors.cardHigh(scheme))
            #expect(outline > variant, "\(scheme): outlineがoutlineVariantより薄い")
        }
    }

    // MARK: - Helpers

    private func assertAllPairs(in scheme: ColorScheme) {
        for pair in pairs {
            let value = contrast(pair.foreground(scheme), pair.background(scheme))
            #expect(
                value >= pair.required,
                "\(pair.label): \(String(format: "%.2f", value)):1 は基準 \(pair.required):1 に届いていない"
            )
        }
    }

    /// WCAG 2.1 のコントラスト比 (L1 + 0.05) / (L2 + 0.05)
    private func contrast(_ a: Color, _ b: Color) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG 2.1 の相対輝度
    private func relativeLuminance(_ color: Color) -> Double {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}
