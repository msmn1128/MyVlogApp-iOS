import Testing
@testable import MyVlogApp

/// ひとこと・タイトルの行分け（VlogLayout.captionLines）。Android: ExportTextFilesTest
@Suite("ひとこと・タイトルの行分け")
struct CaptionLinesTests {

    @Test("改行コードの種類によらず同じ行に分かれ、行に改行コードが残らない")
    func splitsAllLineBreaks() {
        #expect(VlogLayout.captionLines("一行目\r\n二行目\r三行目\n四行目") == ["一行目", "二行目", "三行目", "四行目"])
    }

    @Test("空行は位置を残すため1行として数える")
    func keepsEmptyLines() {
        #expect(VlogLayout.captionLines("上\r\n\r\n下") == ["上", "", "下"])
    }

    @Test("改行が無ければ1行、空文字も1行（空行）")
    func singleLine() {
        #expect(VlogLayout.captionLines("ひとこと") == ["ひとこと"])
        #expect(VlogLayout.captionLines("") == [""])
    }
}
