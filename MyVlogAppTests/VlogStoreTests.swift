import Foundation
import Testing
@testable import MyVlogApp

// =====================================================================================
// VlogStore の編集・追加・一時保存の振る舞い。
//
// VlogStoreは@MainActorでUserDefaultsへ書くため、以前は「テストできない」として
// 対象外にしていた。保存先を差し替えられるようにした（VlogStore.init(defaults:)）ので、
// 使い捨ての保存領域を渡せばテストホストの実データを汚さずに検証できる。
// Android側で言えば TimelineStore / ProjectsController に当たる層で、
// あちらではJVM単体テストが1件も無い部分。
// =====================================================================================

/// - Parameter testName: 領域の名前に使うテスト名。既定値の`#function`は**呼び出し側**で
///   評価されるので、テスト関数から直接呼んでも、下のヘルパー経由で呼んでも
///   そのテスト自身の名前が入る（ヘルパー側も`#function`を既定値にして中継すること）。
@MainActor
private func makeStore(_ testName: String = #function) -> VlogStore {
    // テストごとに別の領域を使い、前のテストの保存内容を持ち越さない。
    //
    // 名前をテスト名から作るのは、実行のたびにUUIDで新しい領域を作っていると
    // シミュレータにplistが際限なく溜まり続けるため（テストからは消す手立てがない）。
    // テストごとには別名なので並列実行でも混ざらず、実行のたびに同じ名前を
    // 使い回すので、作る前に空にしておけば前回の内容も残らない。
    let suiteName = "VlogStoreTests.\(testName)"
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
    return VlogStore(defaults: UserDefaults(suiteName: suiteName)!)
}

/// フォトライブラリ由来のクリップ。重複判定はassetIdentifierで行うので、
/// 「同じ動画」を表したいときは同じidentifierを渡す
@MainActor
private func photoClip(_ identifier: String, shotAtMillis: Int64 = 0) -> VlogClip {
    var clip = TestClip.make(shotAtMillis: shotAtMillis)
    clip.assetIdentifier = identifier
    return clip
}

/// ファイル取り込みのクリップ。重複判定は中身の指紋（contentKey）で行うので、
/// 「同じ動画」を表したいときは同じ指紋を渡す
@MainActor
private func fileClip(_ contentKey: String, shotAtMillis: Int64 = 0) -> VlogClip {
    var clip = TestClip.make(shotAtMillis: shotAtMillis)
    clip.contentKey = contentKey
    return clip
}

@MainActor
@Suite("VlogStore: 動画の追加")
struct VlogStoreAddClipsTests {

    @Test("撮影日時順の位置へ差し込む")
    func insertsInShotOrder() {
        let store = makeStore()
        store.addClips([photoClip("c", shotAtMillis: 300), photoClip("a", shotAtMillis: 100)])
        store.addClips([photoClip("b", shotAtMillis: 200)])

        #expect(store.clips.map(\.assetIdentifier) == ["a", "b", "c"])
    }

    @Test("追加した中で最も古いものを選択する")
    func selectsOldestAdded() {
        let store = makeStore()
        store.addClips([photoClip("old", shotAtMillis: 100), photoClip("new", shotAtMillis: 900)])
        #expect(store.selectedClip?.assetIdentifier == "old")
    }

    @Test("すでにタイムラインにある動画はスキップし、件数を返す")
    func skipsDuplicates() {
        let store = makeStore()
        store.addClips([photoClip("a", shotAtMillis: 100)])

        let result = store.addClips([photoClip("a", shotAtMillis: 100), photoClip("b", shotAtMillis: 200)])

        #expect(result.alreadyPresent == 1)
        #expect(result.overLimit == 0)
        #expect(store.clips.count == 2)
        #expect(store.clips.map(\.assetIdentifier) == ["a", "b"])
    }

    @Test("ファイル取り込みは中身の指紋で重複を弾く")
    func fileClipsAreDeduplicatedByContentKey() {
        // 回帰テスト: Documentsへ毎回別名でコピーするためパスが手がかりにならず、
        // 以前は同じ動画を2回選んでも重複を検知できなかった（FileContentKey参照）
        let store = makeStore()
        store.addClips([fileClip("same", shotAtMillis: 100)])

        let result = store.addClips([fileClip("same", shotAtMillis: 100)])

        #expect(result.alreadyPresent == 1)
        #expect(store.clips.count == 1)
    }

    @Test("指紋が違えば別の動画として追加する")
    func differentContentKeysAreBothAdded() {
        let store = makeStore()
        store.addClips([fileClip("a", shotAtMillis: 100)])
        let result = store.addClips([fileClip("b", shotAtMillis: 200)])

        #expect(result.alreadyPresent == 0)
        #expect(store.clips.count == 2)
    }

    @Test("1回の操作で同じ動画を2つ選んでも、入るのは1本だけ")
    func duplicatesWithinOneBatchAreCollapsed() {
        // タイムラインにはまだ無いので、追加していく途中の分も見ていかないと両方入ってしまう
        let store = makeStore()

        let result = store.addClips([
            fileClip("same", shotAtMillis: 100),
            fileClip("same", shotAtMillis: 100)
        ])

        #expect(result.alreadyPresent == 1)
        #expect(store.clips.count == 1)
    }

    @Test("指紋を持たない古い保存データは、従来どおり重複判定の対象外")
    func clipsWithoutContentKeyAreNotDeduplicated() {
        // 指紋を持たせる前に保存したクリップはcontentKeyがnil。
        // 判定材料が無いので弾かない（誤って消さないほうを選ぶ）
        let store = makeStore()
        store.addClips([TestClip.make(shotAtMillis: 100)])
        let result = store.addClips([TestClip.make(shotAtMillis: 100)])

        #expect(result.alreadyPresent == 0)
        #expect(store.clips.count == 2)
    }

    @Test("上限（100本）を超える分は入れず、件数を返す")
    func respectsMaxClips() {
        let store = makeStore()
        let limit = VlogLayout.maxClips
        store.addClips((0..<limit).map { photoClip("clip-\($0)", shotAtMillis: Int64($0)) })
        #expect(store.clips.count == limit)

        let result = store.addClips([photoClip("over-1"), photoClip("over-2")])

        #expect(store.clips.count == limit)   // 1本も増えない
        #expect(result.overLimit == 2)
        #expect(result.alreadyPresent == 0)
    }

    @Test("上限に一部だけ収まるときは、入る分だけ入れて残りを数える")
    func partiallyFitsUnderLimit() {
        let store = makeStore()
        let limit = VlogLayout.maxClips
        store.addClips((0..<(limit - 1)).map { photoClip("clip-\($0)", shotAtMillis: Int64($0)) })

        let result = store.addClips([photoClip("x", shotAtMillis: 9_001), photoClip("y", shotAtMillis: 9_002)])

        #expect(store.clips.count == limit)
        #expect(result.overLimit == 1)
    }

    @Test("弾いたクリップは rejected で返す（Documentsのコピーを消せるように）")
    func rejectedClipsAreReturned() {
        let store = makeStore()
        store.addClips([photoClip("a")])

        let result = store.addClips([photoClip("a"), photoClip("b")])

        #expect(result.rejected.map(\.assetIdentifier) == ["a"])
    }

    @Test("空の配列を渡しても何も起きない")
    func emptyInput() {
        let store = makeStore()
        let result = store.addClips([])
        #expect(store.clips.isEmpty)
        #expect(result.alreadyPresent == 0 && result.overLimit == 0)
    }
}

@MainActor
@Suite("VlogStore: 編集操作")
struct VlogStoreEditingTests {

    /// 区切りを持つクリップ1本だけのタイムラインを用意する
    /// （`testName`はmakeStoreへ中継するだけ。既定値の評価位置についてはmakeStoreのコメント参照）
    private func storeWithSplitClip(_ testName: String = #function) -> VlogStore {
        let store = makeStore(testName)
        store.addClips([
            {
                var clip = TestClip.make(
                    durationMs: 10_000, startMs: 6_000, endMs: 8_000,
                    texts: TestClip.segments([(0, "A"), (1_000, "B"), (5_000, "C")])
                )
                clip.assetIdentifier = "clip"
                return clip
            }()
        ])
        return store
    }

    @Test("区間ごと移動でトリムより手前の区切りが潰れない")
    func moveTrimKeepsSplitSpacing() {
        // TimelineShiftTests と同じ回帰を、実際に使われる経路（store）で確かめる
        let store = storeWithSplitClip()
        let moved = store.moveTrim(targetStartMs: 0)

        #expect(moved?.startMs == 5_400)
        #expect(moved?.endMs == 7_400)   // 幅2000msは保たれる
        #expect(store.selectedClip?.texts.map(\.startMs) == [0, 400, 4_400])
    }

    @Test("区間ごと移動でも、トリムの幅は変わらない")
    func moveTrimKeepsSpan() {
        let store = storeWithSplitClip()
        let before = store.selectedClip!.trimmedDurationMs
        store.moveTrim(targetStartMs: 9_999)
        #expect(store.selectedClip?.trimmedDurationMs == before)
    }

    @Test("分割は、端に寄りすぎていると理由を知らせて実行しない")
    func splitTooCloseToEdge() {
        let store = makeStore()
        store.addClips([photoClip("a")])   // 尺10秒・全区間選択

        #expect(store.splitAt(positionMs: 100) == nil)
        #expect(store.toastMessage == "区切る位置が端に寄りすぎています")
        #expect(store.selectedClip?.texts.count == 1)
    }

    @Test("分割は、すぐ近くに区切りがあると理由を知らせて実行しない")
    func splitTooCloseToExistingSplit() {
        let store = makeStore()
        var clip = TestClip.make(texts: TestClip.segments([(0, "A"), (5_000, "B")]))
        clip.assetIdentifier = "a"
        store.addClips([clip])

        #expect(store.splitAt(positionMs: 5_100) == nil)
        #expect(store.toastMessage == "すぐ近くに区切りがあります")
        #expect(store.selectedClip?.texts.count == 2)
    }

    @Test("条件を満たせば分割でき、新しい区間には既定の文言が入る")
    func splitSucceeds() {
        let store = makeStore()
        store.addClips([photoClip("a")])

        let index = store.splitAt(positionMs: 5_000)

        #expect(index == 1)
        #expect(store.selectedClip?.texts.count == 2)
        #expect(store.selectedClip?.texts[1].text == TextSegment.defaultText)
        #expect(store.toastMessage == nil)
    }

    @Test("削除すると選択位置が範囲内へ詰められる")
    func deleteAdjustsSelection() {
        let store = makeStore()
        store.addClips([photoClip("a", shotAtMillis: 1), photoClip("b", shotAtMillis: 2)])
        store.selectedIndex = 1

        store.deleteClip(at: 1)

        #expect(store.clips.count == 1)
        #expect(store.selectedIndex == 0)
    }

    @Test("選択より手前を削除しても、選択は同じクリップに残る")
    func deleteBeforeSelectionKeepsSameClip() {
        // 回帰テスト: 以前は min(si, count-1) だけで詰めていたため、手前を消すと
        // 選択が「別のクリップ」へ移っていた（indexは同じでも中身が変わる）
        let store = makeStore()
        store.addClips([
            photoClip("a", shotAtMillis: 1),
            photoClip("b", shotAtMillis: 2),
            photoClip("c", shotAtMillis: 3)
        ])
        store.selectedIndex = 2   // "c" を選択中

        store.deleteClip(at: 0)   // "a" を削除

        #expect(store.clips.map(\.assetIdentifier) == ["b", "c"])
        #expect(store.selectedClip?.assetIdentifier == "c")
    }

    @Test("選択中のクリップを削除すると、次のクリップが選択される")
    func deleteSelectedSelectsNext() {
        // ContentViewはselectedClip?.idの変化で再生を読み込み直す。
        // ここで選択の中身が入れ替わることが、その仕組みの前提になっている
        let store = makeStore()
        store.addClips([
            photoClip("a", shotAtMillis: 1),
            photoClip("b", shotAtMillis: 2),
            photoClip("c", shotAtMillis: 3)
        ])
        store.selectedIndex = 1   // "b" を選択中

        store.deleteClip(at: 1)

        #expect(store.selectedIndex == 1)
        #expect(store.selectedClip?.assetIdentifier == "c")   // indexは同じでも中身は変わる
    }

    @Test("末尾を削除したら、選択は新しい末尾へ詰められる")
    func deleteLastClampsSelection() {
        let store = makeStore()
        store.addClips([photoClip("a", shotAtMillis: 1), photoClip("b", shotAtMillis: 2)])
        store.selectedIndex = 1

        store.deleteClip(at: 1)

        #expect(store.selectedIndex == 0)
        #expect(store.selectedClip?.assetIdentifier == "a")
    }

    @Test("全削除すると選択が外れる")
    func deleteAllClearsSelection() {
        let store = makeStore()
        store.addClips([photoClip("a"), photoClip("b")])
        store.deleteAllClips()

        #expect(store.clips.isEmpty)
        #expect(store.selectedIndex == nil)
    }

    @Test("削除は「もとに戻す」で復帰できる")
    func deleteIsUndoable() {
        let store = makeStore()
        store.addClips([photoClip("a"), photoClip("b")])
        store.deleteAllClips()
        #expect(store.canUndo)

        store.undo()
        #expect(store.clips.count == 2)
    }
}

@MainActor
@Suite("VlogStore: もとに戻す / やり直す")
struct VlogStoreHistoryTests {

    /// （`testName`はmakeStoreへ中継するだけ。既定値の評価位置についてはmakeStoreのコメント参照）
    private func storeWithClip(_ testName: String = #function) -> VlogStore {
        let store = makeStore(testName)
        store.addClips([photoClip("a")])
        return store
    }

    @Test("同じ操作の連打は1件にまとめる")
    func coalescesSameTag() {
        let store = storeWithClip()
        let before = store.undoStack.count

        // トリムのドラッグ相当。900ms以内の連続なので1件にまとまる
        for ms in stride(from: Int64(1_000), to: 1_500, by: 100) {
            store.updateTrim(startMs: ms, endMs: 9_000)
        }
        #expect(store.undoStack.count == before + 1)
    }

    @Test("別の操作を挟んだら、同じタグでも新しい履歴として積む")
    func doesNotCoalesceAcrossOtherEdits() {
        // 回帰テスト: 以前はタグごとに最終時刻を辞書で持っていたため、間に別の操作を
        // 挟んでも同じタグなら900ms以内だとまとめられ、その編集が戻せなくなっていた
        let store = storeWithClip()

        store.updateTrim(startMs: 1_000, endMs: 9_000)
        let afterFirstTrim = store.undoStack.count

        store.updateText("A", segmentIndex: 0)   // 別のタグ
        store.updateTrim(startMs: 2_000, endMs: 9_000)   // 最初と同じタグ

        #expect(store.undoStack.count == afterFirstTrim + 2)
    }

    @Test("タグの無い操作は必ず1件ずつ積む")
    func untaggedEditsAlwaysRecord() {
        let store = storeWithClip()
        let before = store.undoStack.count

        store.splitAt(positionMs: 3_000)
        store.splitAt(positionMs: 6_000)

        #expect(store.undoStack.count == before + 2)
    }

    @Test("もとに戻した直後の同じ操作は、まとめずに積む")
    func undoResetsCoalescing() {
        // 回帰テスト: undo/redoでまとめ判定をリセットしないと、戻した直後の編集が
        // 「続きの操作」とみなされて履歴に積まれず、もう一度戻せなくなっていた
        let store = storeWithClip()

        store.updateTrim(startMs: 1_000, endMs: 9_000)
        store.undo()
        let depthAfterUndo = store.undoStack.count

        // 直前の編集と同じタグ・900ms以内だが、undoを挟んでいるので新しい1件として積まれる
        store.updateTrim(startMs: 2_000, endMs: 9_000)

        #expect(
            store.undoStack.count == depthAfterUndo + 1,
            "もとに戻した直後の編集が履歴に積まれていない"
        )
    }

    @Test("やり直すと、戻す前の状態へ進める")
    func redo() {
        let store = storeWithClip()
        store.updateTrim(startMs: 1_000, endMs: 9_000)

        store.undo()
        #expect(store.selectedClip?.startMs == 0)

        store.redo()
        #expect(store.selectedClip?.startMs == 1_000)
    }

    @Test("新しい編集をすると、やり直せなくなる")
    func newEditClearsRedo() {
        let store = storeWithClip()
        store.updateTrim(startMs: 1_000, endMs: 9_000)
        store.undo()
        #expect(store.canRedo)

        store.splitAt(positionMs: 5_000)
        #expect(!store.canRedo)
    }

    @Test("履歴の上限を超えたら古いものから捨てる")
    func respectsHistoryLimit() {
        let store = storeWithClip()
        // タグ無しの操作を上限より多く積む（分割と解除を交互に繰り返す）
        for _ in 0..<(store.maxUndo + 10) {
            store.splitAt(positionMs: 5_000)
            store.removeSplitNear(positionMs: 5_000)
        }
        #expect(store.undoStack.count == store.maxUndo)
    }
}

@MainActor
@Suite("VlogStore: 一時保存")
struct VlogStoreProjectsTests {

    @Test("同名で保存すると連番が付く")
    func duplicateNamesGetSuffix() {
        let store = makeStore()
        store.addClips([photoClip("a")])

        #expect(store.saveCurrentProject(name: "旅行") == "旅行")
        #expect(store.saveCurrentProject(name: "旅行") == "旅行 (1)")
        #expect(store.saveCurrentProject(name: "旅行") == "旅行 (2)")
        #expect(store.savedProjects.count == 3)
    }

    @Test("続けて保存してもidが重複しない")
    func idsAreUnique() {
        // 回帰テスト: idは保存時刻(ms)だった。同じミリ秒に2件保存するとidが衝突し、
        // 片方を削除したつもりが deleteSavedProject の removeAll で両方消えていた
        let store = makeStore()
        store.addClips([photoClip("a")])
        for i in 0..<8 { store.saveCurrentProject(name: "p\(i)") }

        let ids = store.savedProjects.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("1件削除しても、他の保存は残る")
    func deleteRemovesOnlyOne() {
        let store = makeStore()
        store.addClips([photoClip("a")])
        for i in 0..<5 { store.saveCurrentProject(name: "p\(i)") }
        let target = store.savedProjects[2].id

        store.deleteSavedProject(id: target)

        #expect(store.savedProjects.count == 4)
        #expect(!store.savedProjects.contains { $0.id == target })
    }

    @Test("上限（20件）に達したら保存しない")
    func respectsProjectLimit() {
        let store = makeStore()
        store.addClips([photoClip("a")])
        for i in 0..<VlogLayout.maxSavedProjects { store.saveCurrentProject(name: "p\(i)") }

        #expect(store.saveCurrentProject(name: "over") == nil)
        #expect(store.savedProjects.count == VlogLayout.maxSavedProjects)
    }

    @Test("動画の読み込み中は保存を断り、理由を知らせる")
    func refusesWhileImporting() {
        let store = makeStore()
        store.addClips([photoClip("a")])
        store.isImporting = true

        #expect(store.saveCurrentProject(name: "x") == nil)
        #expect(store.toastMessage == "動画を読み込み中です。終わってからもう一度お試しください")
        #expect(store.savedProjects.isEmpty)
    }

    @Test("動画が1本も読めない保存は、読み出さずに断る")
    func refusesUnreadableProject() {
        // 回帰テスト: 以前は無効なクリップを除外した結果が空でも置き換えており、
        // 作業中のタイムラインが消えていた
        let store = makeStore()
        store.addClips([photoClip("working", shotAtMillis: 1)])

        // 存在しないファイルだけを含む保存（動画を移動・削除したあとの状態）
        var missing = TestClip.make()
        missing.relativeFilePath = "does-not-exist-\(UUID().uuidString).mov"
        let project = SavedProject(
            id: 1, name: "古い保存", savedAt: 1, clipCount: 1, totalMs: 0, clips: [missing]
        )

        store.loadProject(project)

        #expect(store.clips.map(\.assetIdentifier) == ["working"])  // 置き換わっていない
        #expect(store.toastMessage?.contains("読み出しませんでした") == true)
    }

    @Test("空の保存はそのまま読み出せる（作業中の内容は空になる）")
    func loadsEmptyProject() {
        let store = makeStore()
        store.addClips([photoClip("working")])
        let project = SavedProject(id: 1, name: "空", savedAt: 1, clipCount: 0, totalMs: 0, clips: [])

        store.loadProject(project)

        #expect(store.clips.isEmpty)
        #expect(store.selectedIndex == nil)
        #expect(store.toastMessage?.contains("もとに戻す") == true)
    }

    @Test("前回の続きは、initが返った時点でもう復元されている")
    func autoSaveIsRestoredSynchronously() throws {
        // 回帰テスト: 復元を Task { await ... } で非同期にしていたため、initが返ってから
        // 復元が走るまでの間にユーザーが操作できてしまい、その編集を復元が上書きしていた。
        // 「initを抜けた直後にもう入っている」ことを確かめれば、その窓が無いと言える。
        let suiteName = "VlogStoreTests.autoSaveIsRestoredSynchronously"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let defaults = UserDefaults(suiteName: suiteName)!

        // 自動保存が書くのと同じ形で、復元できるクリップを1本仕込んでおく。
        // 参照先が実在しないと validClips に落とされるので、実ファイルを用意する
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).mov")
        try Data([0x00]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var clip = TestClip.make(shotAtMillis: 100)
        clip.fileURL = file
        defaults.set(try JSONEncoder().encode([clip]), forKey: "vlog_autosave_v1_clips")

        let store = VlogStore(defaults: defaults)

        // ここまでにawaitを1つも挟んでいない。それでもう入っているのが要点
        #expect(store.clips.count == 1, "initを抜けた時点で復元が済んでいない")
        #expect(store.selectedIndex == 0)
        // 復元直後を起点にするので、いきなり「もとに戻す」で空へ戻れてはいけない
        #expect(!store.canUndo)
    }

    @Test("読み出しは「もとに戻す」で読み出す前へ戻せる")
    func loadIsUndoable() {
        let store = makeStore()
        store.addClips([photoClip("working")])
        let project = SavedProject(id: 1, name: "空", savedAt: 1, clipCount: 0, totalMs: 0, clips: [])

        store.loadProject(project)
        store.undo()

        #expect(store.clips.map(\.assetIdentifier) == ["working"])
    }
}
