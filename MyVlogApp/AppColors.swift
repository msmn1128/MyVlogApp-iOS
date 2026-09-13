import SwiftUI

enum AppColors {
    static let primary         = Color(red: 0.55, green: 0.27, blue: 0.87)
    static let lightBackground = Color(red: 0.97, green: 0.95, blue: 1.00)
    static let darkBackground  = Color(red: 0.10, green: 0.08, blue: 0.14)
    static let lightCard       = Color.white
    static let darkCard        = Color(red: 0.16, green: 0.13, blue: 0.22)
    static let waveformFill    = Color(red: 0.55, green: 0.27, blue: 0.87)
    static let waveformDim     = Color(red: 0.55, green: 0.27, blue: 0.87).opacity(0.25)
    // Split-line is a step deeper (light) / brighter (dark) than the waveform fill
    static let splitLineLight  = Color(red: 0.38, green: 0.06, blue: 0.65)
    static let splitLineDark   = Color(red: 0.78, green: 0.60, blue: 1.00)

    static func splitLine(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? splitLineDark : splitLineLight
    }
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkBackground : lightBackground
    }
    static func card(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkCard : lightCard
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
    static let titleVlogFontSize: CGFloat = 170
    static let titleDateFontSize: CGFloat = 65
    static let titleSpacing:      CGFloat = 28
    static let titleCardDuration: Double  = 2.0
}
