import Testing
@testable import MyVlogApp

/// タイトルカードへ焼き込む文言の決め方（Android: VlogExporter.export の customTitleText ?: firstDate）。
///
/// 書き出しそのものは実ファイルとAVFoundationが要るのでテストできないが、「何を焼き込むか」の
/// 判断はこの純粋関数だけで決まる。以前はタイトル作成ダイアログ側にも同じ判定があり、
/// 片方だけ前後の空白を落としているというズレがあったため、1箇所に集約したうえでここで守る。
@Suite("タイトルカードの文言")
struct ExportTitleTests {

    @Test("自由入力があればそれを使う")
    func usesCustomText() {
        #expect(ExportManager.resolveTitleText(
            customTitleText: "夏の思い出", firstClipDateText: "2026/09/20"
        ) == "夏の思い出")
    }

    @Test("自由入力が無ければ先頭クリップの撮影日を使う")
    func fallsBackToDate() {
        #expect(ExportManager.resolveTitleText(
            customTitleText: nil, firstClipDateText: "2026/09/20"
        ) == "2026/09/20")
        #expect(ExportManager.resolveTitleText(
            customTitleText: "", firstClipDateText: "2026/09/20"
        ) == "2026/09/20")
    }

    @Test("空白や改行だけの入力は「入力なし」として撮影日へ戻す")
    func blankTextFallsBackToDate() {
        // 回帰テスト: trimせずに見ていたため、見た目は空なのに空白がそのまま
        // タイトルカードへ焼き込まれていた
        #expect(ExportManager.resolveTitleText(
            customTitleText: "   ", firstClipDateText: "2026/09/20"
        ) == "2026/09/20")
        #expect(ExportManager.resolveTitleText(
            customTitleText: "\n\n", firstClipDateText: "2026/09/20"
        ) == "2026/09/20")
    }

    @Test("前後の空白は落とすが、途中の改行（複数行のタイトル）は残す")
    func trimsEdgesButKeepsLineBreaks() {
        #expect(ExportManager.resolveTitleText(
            customTitleText: "  夏の思い出  ", firstClipDateText: "2026/09/20"
        ) == "夏の思い出")
        // createTitleCardが改行で行を分けて積むので、途中の改行は意味を持つ
        #expect(ExportManager.resolveTitleText(
            customTitleText: "夏の\n思い出", firstClipDateText: "2026/09/20"
        ) == "夏の\n思い出")
    }

    @Test("撮影日も空なら空文字（タイトルは「Vlog.」だけになる）")
    func emptyEverywhere() {
        #expect(ExportManager.resolveTitleText(customTitleText: nil, firstClipDateText: "") == "")
    }
}
