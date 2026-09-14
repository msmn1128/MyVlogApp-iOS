import SwiftUI
import UIKit

/// Android版 ui/theme/Color.kt のMaterial3パープルパレットと同じ値を移植したもの。
/// ダイナミックカラーは使わず、常にこのパープル基調で固定する。
enum AppColors {
    // --- Light ---
    static let lightPrimary            = Color(hex: 0x6B3FD4)
    static let lightOnPrimary          = Color.white
    static let lightOnPrimaryContainer = Color(hex: 0x23005C)
    static let lightPrimaryContainer   = Color(hex: 0xE9DDFF)
    static let lightOnSecondaryContainer = Color(hex: 0x1E192B)
    static let lightSecondaryContainer   = Color(hex: 0xE8DEF8)
    static let lightBackground         = Color(hex: 0xFDF7FF)
    static let lightOnSurfaceVariant   = Color(hex: 0x49454E)
    static let lightOutlineVariant     = Color(hex: 0xCAC4CF)
    static let lightSurfaceContainer       = Color(hex: 0xF3EDF7)
    static let lightSurfaceContainerHigh   = Color(hex: 0xECE6F0)
    static let lightError               = Color(hex: 0xBA1A1A)
    static let lightSplitMarker         = Color(hex: 0x4A0E86)
    static let lightOnSplitMarker       = Color.white

    // --- Dark ---
    static let darkPrimary            = Color(hex: 0xCFBCFF)
    static let darkOnPrimary          = Color(hex: 0x390094)
    static let darkOnPrimaryContainer = Color(hex: 0xE9DDFF)
    static let darkPrimaryContainer   = Color(hex: 0x5228BB)
    static let darkOnSecondaryContainer = Color(hex: 0xE8DEF8)
    static let darkSecondaryContainer   = Color(hex: 0x4A4458)
    static let darkBackground         = Color(hex: 0x141218)
    static let darkOnSurfaceVariant   = Color(hex: 0xCAC4CF)
    static let darkOutlineVariant     = Color(hex: 0x49454E)
    static let darkSurfaceContainer       = Color(hex: 0x211F26)
    static let darkSurfaceContainerHigh   = Color(hex: 0x2B2930)
    static let darkError               = Color(hex: 0xFFB4AB)
    static let darkSplitMarker         = Color(hex: 0xC77DFF)
    static let darkOnSplitMarker       = Color(hex: 0x2C0060)

    static var primary:            Color { primary(current) }
    static var waveformFill:       Color { primary(current) }
    static var waveformDim:        Color { primary(current).opacity(0.25) }

    static func primary(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkPrimary : lightPrimary }
    static func onPrimary(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkOnPrimary : lightOnPrimary }
    static func background(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkBackground : lightBackground }
    /// カード（タイムライン等の面）。Android surfaceContainer相当
    static func card(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkSurfaceContainer : lightSurfaceContainer }
    /// カードより一段明るい面（選択中タイル等）。Android surfaceContainerHigh相当
    static func cardHigh(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkSurfaceContainerHigh : lightSurfaceContainerHigh }
    static func primaryContainer(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkPrimaryContainer : lightPrimaryContainer }
    static func onPrimaryContainer(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkOnPrimaryContainer : lightOnPrimaryContainer }
    /// Android FilledTonalButtonの既定配色（secondaryContainer）。動画を追加/書き出しボタンで使う
    static func secondaryContainer(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkSecondaryContainer : lightSecondaryContainer }
    static func onSecondaryContainer(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkOnSecondaryContainer : lightOnSecondaryContainer }
    static func onSurfaceVariant(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkOnSurfaceVariant : lightOnSurfaceVariant }
    static func outlineVariant(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkOutlineVariant : lightOutlineVariant }
    static func error(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkError : lightError }
    static func splitLine(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkSplitMarker : lightSplitMarker }
    static func onSplitLine(_ scheme: ColorScheme) -> Color { scheme == .dark ? darkOnSplitMarker : lightOnSplitMarker }

    /// SwiftUIの@Environment外（プレビュー等）から使う簡易フォールバック
    private static var current: ColorScheme {
        UITraitCollection.current.userInterfaceStyle == .dark ? .dark : .light
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }
}

/// Layout/render constants shared between preview and export
enum VlogLayout {
    static let canvasWidth:  CGFloat = 1920
    static let canvasHeight: CGFloat = 1080
    static let hitokoroFontSize:  CGFloat = 70
    static let hitokoroLineGap:   CGFloat = 10
    static let timestampFontSize: CGFloat = 60
    static let timestampRightPad: CGFloat = 40
    static let titleVlogFontSize: CGFloat = 150
    static let titleDateFontSize: CGFloat = 50
    static let titleVlogYOffset:  CGFloat = -70
    static let titleDateYOffset:  CGFloat = 80
    static let titleCardDuration: Double  = 2.0
    /// タイトルカードのSFXを鳴らし始めるフレーム番号（1始まり、30fps）。Android: TITLE_SFX_FRAME_NUMBER
    static let titleSfxFrameNumber: Int = 21

    /// Android: TOOLBAR_BUTTON_SIZE / TOOLBAR_ICON_SIZE
    static let toolbarButtonSize: CGFloat = 48
    static let toolbarIconSize:   CGFloat = 20

    /// 「ひとこと」複数行ブロックの先頭行の上端Y（キャンバス上下中央に配置）。
    /// PreviewView（SwiftUI描画）とExportManager（CGContext描画）の両方で使う、
    /// 数値としては完全に同一の計算（過去にここがズレて「プレビューと書き出しの
    /// 黒帯基準ズレ」という不具合になったことがあるため、1箇所にまとめている）。
    static func hitokotoBlockTop(lineCount: Int, canvasHeight: CGFloat, fontSize: CGFloat, lineGap: CGFloat) -> CGFloat {
        guard lineCount > 0 else { return canvasHeight * 0.5 }
        let lineHeight = fontSize + lineGap
        let totalHeight = lineHeight * CGFloat(lineCount) - lineGap
        return canvasHeight * 0.5 - totalHeight / 2
    }
}
