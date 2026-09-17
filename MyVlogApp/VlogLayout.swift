import SwiftUI

/// Layout/render constants shared between preview and export.
/// 定数テーブルで可変状態を持たないため、@MainActorがプロジェクト全体の既定
/// （SWIFT_DEFAULT_ACTOR_ISOLATION）になっていても、どのactorからでも
/// awaitなしで安全に参照できるようnonisolatedにしてある
/// （ExportWorkerなど@MainActor以外のactorから参照するため）
nonisolated enum VlogLayout {
    static let canvasWidth:  CGFloat = 1920
    static let canvasHeight: CGFloat = 1080
    static let canvasSize: CGSize = CGSize(width: canvasWidth, height: canvasHeight)
    static let hitokotoFontSize:  CGFloat = 70
    static let hitokotoLineGap:   CGFloat = 10
    static let timestampFontSize: CGFloat = 60
    static let timestampRightPad: CGFloat = 40
    static let titleVlogFontSize: CGFloat = 150
    static let titleDateFontSize: CGFloat = 50
    static let titleVlogYOffset:  CGFloat = -70
    static let titleDateYOffset:  CGFloat = 80
    /// タイトルカードの文言が複数行になったときの行間。Android: TITLE_DATE_LINE_SPACING_PT
    static let titleDateLineSpacing: CGFloat = 10
    /// ファイル名に使う文言の長さ上限。Android: TITLE_FILENAME_MAX_CHARS
    static let titleFilenameMaxChars: Int = 60
    static let titleCardDuration: Double  = 2.0
    /// タイトルカードのSFXを鳴らし始めるフレーム番号（1始まり、30fps）。Android: TITLE_SFX_FRAME_NUMBER
    static let titleSfxFrameNumber: Int = 21
    /// タイトルカードのフェードアウトが始まるフレーム番号（0始まり）。Android: FADE_START_FRAME
    static let titleFadeStartFrame: Int = 30
    /// フェードアウトにかけるフレーム数。Android: FADE_FRAME_COUNT
    static let titleFadeFrameCount: Int = 20

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
