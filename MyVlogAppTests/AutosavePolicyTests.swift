import Testing
@testable import MyVlogApp

/// 前回の続き（自動保存）をいつ書き換えてよいか（AutosavePolicy）。Android: AutosavePolicyTest
@Suite("自動保存を書き換えてよいか")
struct AutosavePolicyTests {

    @Test("復元が済むまでは書かない")
    func nothingIsSavedBeforeTheRestoreFinishes() {
        var policy = AutosavePolicy()
        // 復元前の空の一覧で、前回の内容を上書きしない
        let save1 = policy.shouldSave(canUndo: true)
        #expect(!save1)
        #expect(!policy.shouldSaveOnExit(canUndo: true))
    }

    @Test("全部復元できた回は、どの変化も書く")
    func afterAFullRestoreEveryChangeIsSaved() {
        var policy = AutosavePolicy()
        policy.onRestored(droppedCount: 0)
        // 撮影時刻の取り直し（履歴に積まれない変化）も書いてよい
        let save2 = policy.shouldSave(canUndo: false)
        #expect(save2)
        #expect(policy.shouldSaveOnExit(canUndo: false))
    }

    @Test("開けない動画を落とした回は、最初の編集まで書かない")
    func afterDroppingUnreadableVideosTheSaveIsKeptUntilTheFirstEdit() {
        var policy = AutosavePolicy()
        policy.onRestored(droppedCount: 2)

        // 編集していない間（開いただけ・撮影時刻の取り直しだけ）は書き換えない
        let save3 = policy.shouldSave(canUndo: false)
        #expect(!save3)
        #expect(!policy.shouldSaveOnExit(canUndo: false))

        // 最初の編集（「もとに戻す」が押せるようになった）からは書く
        let save4 = policy.shouldSave(canUndo: true)
        #expect(save4)
        // 保留は一度解けたら戻らない（そのあと「もとに戻す」を押し切っても書く）
        let save5 = policy.shouldSave(canUndo: false)
        #expect(save5)
        #expect(policy.shouldSaveOnExit(canUndo: false))
    }

    @Test("編集した直後にバックグラウンドへ回っても、そのときに書く")
    func editingRightBeforeLeavingIsStillSaved() {
        var policy = AutosavePolicy()
        policy.onRestored(droppedCount: 1)
        #expect(policy.shouldSaveOnExit(canUndo: true))
    }
}
