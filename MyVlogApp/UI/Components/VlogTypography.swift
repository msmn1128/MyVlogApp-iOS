import SwiftUI

// =====================================================================================
// 画面UIの文字を、端末の文字サイズ設定（Dynamic Type）へ追従させるための道具。
//
// SwiftUIの`Font.system(size:)`は固定ptで、設定で文字を大きくしても一切変わらない。
// カスタムフォントには`Font.custom(_:size:relativeTo:)`というスケール付きの作り方があるが、
// システムフォントには対応するものが無い。そこで`@ScaledMetric`で「いまの倍率」を
// 取り出し、設計時のポイント数へ掛けて組み立てる。
//
// ⚠️ 書き出し映像に焼き込まれる文字には使わないこと。
// PreviewViewの「ひとこと」「撮影時刻」は ExportWorker+Drawing の描画と数式レベルで
// 一致していなければならず、その基準が VlogLayout の固定ptサイズ。
// あそこをDynamic Typeでスケールさせると、プレビューと書き出しの見た目がずれる
// （過去に「プレビューと書き出しの黒帯基準ズレ」として直した不具合と同じ種類の事故になる）。
// =====================================================================================

/// 文字サイズ設定の倍率を掛けたシステムフォントを当てる
private struct ScaledSystemFont: ViewModifier {
    /// 既定のbodyサイズに対する、いまの文字サイズ設定の倍率。
    /// 1を渡しておくと、そのまま倍率として読める
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design

    func body(content: Content) -> some View {
        content.font(.system(size: size * scale, weight: weight, design: design))
    }
}

extension View {
    /// Dynamic Typeに追従するシステムフォントを当てる（画面UIの文字用）。
    /// `.font(.system(size:weight:design:))`をそのまま置き換えられる形にしてある。
    func vlogFont(
        _ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default
    ) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight, design: design))
    }
}

extension VlogLayout {
    /// ツールバーのアイコンボタンを文字サイズ設定で伸ばすときの上限倍率。
    ///
    /// 文字そのものは設定どおり大きくするが、アイコンボタンの枠まで最大（約3.1倍）まで
    /// 広げると、横一列に10個並ぶ操作バーが画面の何倍もの長さになり、端のボタンへ
    /// 辿り着くのに延々スクロールすることになる（48pt→149ptで、画面に2つ半しか入らない）。
    /// 押しやすさが確保できるところで頭打ちにするほうが、結果として使いやすい。
    ///
    /// ここは書き出し映像には一切関わらない画面UIだけの寸法なので、
    /// VlogLayoutの他の定数（キャンバス・焼き込み文字）とは性質が違う点に注意。
    static let toolbarScaleCap: CGFloat = 1.6

    /// `@ScaledMetric`で伸ばしたツールバーの寸法へ、上の上限を掛ける
    static func cappedToolbarSize(_ scaled: CGFloat) -> CGFloat {
        min(scaled, toolbarButtonSize * toolbarScaleCap)
    }
}

extension Font {
    /// Dynamic Typeに追従するアプリ内蔵フォント（タイトル作成ダイアログの入力欄など）。
    /// こちらはSwiftUI標準の`relativeTo:`がそのまま使える。
    static func vlogCustom(_ name: String, size: CGFloat) -> Font {
        .custom(name, size: size, relativeTo: .body)
    }
}
