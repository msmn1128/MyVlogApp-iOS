import Foundation
import Testing
@testable import MyVlogApp

/// 表示整形と、画面に出す通知文の組み立て。Android: MergeAndFormatTest / AddClipsSpecTest / ProjectSpecTest
@Suite("Formatters")
struct FormattersTests {

    // MARK: - 保存名の連番

    @Test("同名が無ければそのまま")
    func uniqueSaveNameNoConflict() {
        #expect(Formatters.uniqueSaveName(base: "9/20", existingNames: []) == "9/20")
        #expect(Formatters.uniqueSaveName(base: "9/20", existingNames: ["9/21"]) == "9/20")
    }

    @Test("同名があれば空いている最初の連番を付ける")
    func uniqueSaveNameWithConflict() {
        #expect(Formatters.uniqueSaveName(base: "旅行", existingNames: ["旅行"]) == "旅行 (1)")
        #expect(Formatters.uniqueSaveName(base: "旅行", existingNames: ["旅行", "旅行 (1)"]) == "旅行 (2)")
        // 途中が空いていればそこへ入る
        #expect(Formatters.uniqueSaveName(base: "旅行", existingNames: ["旅行", "旅行 (2)"]) == "旅行 (1)")
    }

    @Test("既定の保存名にも連番が付く")
    func defaultSaveNameDeduplicates() {
        // "M/d"の実際の文字列は端末のタイムゾーン依存なので、まず衝突なしで得てから比べる
        let date = Date(timeIntervalSince1970: 1_758_000_000)
        let base = Formatters.defaultSaveName(baseDate: date, existingNames: [])
        #expect(Formatters.defaultSaveName(baseDate: date, existingNames: [base]) == "\(base) (1)")
    }

    // MARK: - 書き出しファイル名

    @Test("書き出しファイル名は「書き出した日付」から作る")
    func exportFileNameUsesExportDate() {
        // 回帰テスト: 以前はタイトルカードの文言をそのままファイル名にしていた。
        // 自由入力は改行やパス区切り文字を含みうるので、日付から作るほうが安全
        // （Android: GalleryOutput.buildDisplayName）
        let name = Formatters.exportFileName(exportedAt: Date(timeIntervalSince1970: 1_758_000_000))

        #expect(name.hasPrefix("Vlog_"))
        #expect(name.hasSuffix(".mp4"))
        // 日付部分は yyyy-MM-dd（スラッシュはファイル名に使えないのでハイフン）
        let datePart = name.dropFirst("Vlog_".count).dropLast(".mp4".count)
        #expect(datePart.count == 10)
        #expect(datePart.filter { $0 == "-" }.count == 2)
        #expect(!name.contains("/"))
    }

    @Test("同じ日に書き出せば同じ名前になる（時刻は入れない）")
    func exportFileNameIgnoresTimeOfDay() {
        let morning = Date(timeIntervalSince1970: 1_758_000_000)
        let later   = morning.addingTimeInterval(60 * 60)   // 1時間後
        #expect(Formatters.exportFileName(exportedAt: morning)
                == Formatters.exportFileName(exportedAt: later))
    }

    // MARK: - 追加時のスキップ通知

    @Test("スキップが1件も無ければ通知しない")
    func noSkipMessage() {
        #expect(Formatters.addSkipMessage(alreadyAdded: 0, unreadable: 0, overLimit: 0) == nil)
    }

    @Test("理由ごとに1行ずつ出す")
    func skipMessagePerReason() {
        #expect(Formatters.addSkipMessage(alreadyAdded: 2, unreadable: 0)
            == "2 件は追加済みのためスキップしました")
        #expect(Formatters.addSkipMessage(alreadyAdded: 0, unreadable: 1)?
            .contains("1 件は読み込めなかったので追加しませんでした") == true)
        #expect(Formatters.addSkipMessage(alreadyAdded: 0, unreadable: 0, overLimit: 3, limit: 100)
            == "3 件は上限（100本）を超えるため追加しませんでした")
    }

    @Test("複数の理由が重なったら改行でつなぐ")
    func skipMessageCombined() {
        let message = Formatters.addSkipMessage(alreadyAdded: 1, unreadable: 2, overLimit: 3)
        let lines = message?.split(separator: "\n") ?? []
        #expect(lines.count == 3)
    }

    // MARK: - 一時保存の読み出し

    @Test("読める動画が1本でもあれば置き換えてよい")
    func canReplaceWhenSomethingLoaded() {
        #expect(Formatters.canReplaceWithProject(loaded: 3, dropped: 0))
        #expect(Formatters.canReplaceWithProject(loaded: 2, dropped: 1))
    }

    @Test("空の保存はそのまま読み出せる")
    func canReplaceWhenProjectIsEmpty() {
        #expect(Formatters.canReplaceWithProject(loaded: 0, dropped: 0))
    }

    @Test("1本も読めないなら置き換えない（作業中のタイムラインが消えてしまうため）")
    func cannotReplaceWhenNothingReadable() {
        #expect(!Formatters.canReplaceWithProject(loaded: 0, dropped: 3))
    }

    @Test("読み出し後の通知には、もとに戻せることを添える")
    func loadedMessage() {
        #expect(Formatters.projectLoadedMessage(dropped: 0).contains("もとに戻す"))
        let partial = Formatters.projectLoadedMessage(dropped: 2)
        #expect(partial.contains("2 件"))
        #expect(partial.contains("もとに戻す"))
    }

    @Test("読み出せなかったときの通知には件数を出す")
    func unreadableMessage() {
        #expect(Formatters.projectUnreadableMessage(dropped: 4).contains("4 件"))
    }

    // MARK: - 尺の表示

    @Test("尺は m:ss 表記")
    func durationLabel() {
        #expect(Formatters.durationLabel(ms: 0) == "0:00")
        #expect(Formatters.durationLabel(ms: 5_000) == "0:05")
        #expect(Formatters.durationLabel(ms: 65_000) == "1:05")
        #expect(Formatters.durationLabel(ms: 600_000) == "10:00")
    }

    @Test("負の尺でも 0:00 として出す（マイナス表記にしない）")
    func durationLabelNegative() {
        #expect(Formatters.durationLabel(ms: -1_000) == "0:00")
    }
}
