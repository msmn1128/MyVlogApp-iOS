//
//  MyVlogAppUITests.swift
//  MyVlogAppUITests
//

import XCTest

/// 起動直後の主要要素と、ひとこと欄まわりのスモークテスト。
///
/// 起動には`launchApp(clipCount:)`（VlogUITestHelpers.swift）を使う。0本を渡しても
/// 起動引数は付くので、保存先が使い捨ての領域に切り替わり、シミュレータに残っている
/// 実際の編集内容に左右されない空の状態から始められる。
final class MyVlogAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 起動直後の主要要素と、追加メニューが開けることを確認する。
    /// PHPickerViewControllerは別プロセスで動くため、動画選択そのものはXCUITestの
    /// スコープ外（app.cellsで拾えない）——そこから先は手動確認に委ねる。
    @MainActor
    func testHomeScreenAndAddMenu() throws {
        let app = launchApp(clipCount: 0)

        XCTAssertTrue(app.staticTexts["タイムライン"].exists)
        XCTAssertTrue(app.staticTexts["ひとこと"].waitForExistence(timeout: 5))

        let addButton = app.buttons["動画を追加"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let photoLibraryItem = app.buttons["フォトライブラリ"]
        let fileItem = app.buttons["ファイルから選択"]
        XCTAssertTrue(photoLibraryItem.waitForExistence(timeout: 5))
        XCTAssertTrue(fileItem.exists)

        // メニューを閉じる（画面外をタップ）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()

        attachScreenshot(app, name: "home_screen")
    }

    /// ひとこと欄はタップ一回でキーボードが開き、アクセサリの「閉じる」で閉じられる。
    ///
    /// 回帰テスト: SwiftUIのジェスチャー配送とUIKitのfirst responder化のタイムラグで
    /// 「1回目のタップではキーボードが開かない」症状があり、touchesBeganでその場で
    /// becomeFirstResponderする実装（TextInputView.swiftのEagerFirstResponderTextView）で
    /// 直している。その入口と出口が両方生きていることを見る。
    @MainActor
    func testHitokotoKeyboardOpensOnFirstTapAndCloses() throws {
        // クリップが無いとひとこと欄は打てない（打った文字の行き先が無いため）ので、1本入れて起動する
        let app = launchApp(clipCount: 1)

        let textView = app.textViews.firstMatch
        XCTAssertTrue(textView.waitForExistence(timeout: 10), "ひとこと欄が見つからない")
        textView.tap()

        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 5),
            "1回目のタップでキーボードが開かなかった"
        )
        attachScreenshot(app, name: "keyboard_open")

        let done = app.buttons["keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "キーボードの「閉じる」が見つからない")
        done.tap()

        XCTAssertTrue(
            waitUntil(timeout: 5) { !app.keyboards.firstMatch.exists },
            "「閉じる」を押してもキーボードが閉じなかった"
        )
        attachScreenshot(app, name: "keyboard_closed")
    }

    /// 横向きのiPhoneでキーボードを出すと、タイムラインを畳んでひとこと欄に高さを回す。
    /// キーボードは開いたまま（ひとこと欄を作り直してフォーカスを失わない）で、閉じればタイムラインが戻る
    @MainActor
    func testTimelineFoldsWhileTypingInLandscape() throws {
        let app = launchApp(clipCount: 1)
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["タイムライン"].waitForExistence(timeout: 5))

        app.textViews.firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "キーボードが開かなかった")
        XCTAssertTrue(
            waitUntil(timeout: 3) { !app.staticTexts["タイムライン"].exists },
            "キーボードを出してもタイムラインが畳まれない"
        )
        // 畳んだあとも入力欄から抜けていない
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "タイムラインを畳んだらキーボードが閉じた")
        app.typeText("横")
        attachScreenshot(app, name: "landscape_typing")

        app.buttons["keyboardDone"].tap()
        XCTAssertTrue(
            app.staticTexts["タイムライン"].waitForExistence(timeout: 5),
            "キーボードを閉じてもタイムラインが戻らない"
        )
    }

    /// 保存したらダイアログを閉じる。上書き（行の長押し）は確認を挟む。ライセンスを開ける
    @MainActor
    func testSaveDialogClosesOnSaveAndConfirmsOverwrite() throws {
        let app = launchApp(clipCount: 1)
        let open = app.buttons["編集内容の保存と読み出し"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))

        open.tap()
        app.buttons["この内容を保存"].tap()
        // 回帰テスト: 開いたままだと続けて押せてしまい、同じ内容が「名前」「名前 (1)」の2件になっていた
        XCTAssertTrue(
            waitUntil(timeout: 3) { !app.buttons["この内容を保存"].exists },
            "保存してもダイアログが閉じない"
        )

        open.tap()
        let row = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "に保存")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "保存した行が見つからない")
        row.press(forDuration: 1.0)
        XCTAssertTrue(app.alerts["上書きしますか"].waitForExistence(timeout: 3), "上書きの前に確認が出ない")
        app.alerts["上書きしますか"].buttons["キャンセル"].tap()

        app.buttons["ライセンス"].tap()
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "M PLUS U")).firstMatch
                .waitForExistence(timeout: 3),
            "ライセンスにフォントの表示が無い"
        )
        attachScreenshot(app, name: "license")
    }

    /// 入力欄をタップした直後に打っても、打った文字が1文字も落ちない。
    ///
    /// Android版（v1.8で修正）では、外からの変更を入力欄へ反映する処理が古い文字で入力欄を巻き戻し、
    /// タップ直後に打つと数文字に1文字が消えていた。iOSは打った文字を入力欄と保存側へ同じ瞬間に流すので
    /// 起きない作りだが、同じ手順（タップ→すぐ打つ→閉じる、を3回）で守っておく
    @MainActor
    func testTypingRightAfterTappingKeepsEveryCharacter() throws {
        let app = launchApp(clipCount: 1)
        let textView = app.textViews.firstMatch
        let words = (1...3).map { "Hello\($0)" }
        for word in words {
            textView.tap()
            app.typeText(word)
            app.buttons["keyboardDone"].tap()
            XCTAssertTrue(waitUntil(timeout: 3) { !app.keyboards.firstMatch.exists })
        }
        // どこに入るかは testTappingToStartTypingAppendsAtTheEnd で見る。ここで見るのは、打った語が
        // 1文字も欠けずに全部あること
        let value = textView.value as? String ?? ""
        for word in words {
            XCTAssertTrue(value.contains(word), "「\(word)」が欠けている（\(value)）")
        }
        XCTAssertEqual(value.count, words.joined().count, "余分な文字か、欠けた文字がある（\(value)）")
    }

    /// 入力欄をタップして打つと、文字の終わりに入る。
    ///
    /// 回帰テスト: 中央ぞろえの入力欄では、UIKitが入力を始めるタップでカーソルを先頭に置くことがあり、
    /// 2回目からは打った文字が頭に入っていた（「A1」→「B2A1」）
    @MainActor
    func testTappingToStartTypingAppendsAtTheEnd() throws {
        let app = launchApp(clipCount: 1)
        let textView = app.textViews.firstMatch
        for word in ["A1", "B2", "C3"] {
            textView.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            app.typeText(word)
            app.buttons["keyboardDone"].tap()
            XCTAssertTrue(waitUntil(timeout: 3) { !app.keyboards.firstMatch.exists })
        }
        XCTAssertEqual(textView.value as? String, "A1B2C3", "入力を始めるタップのあとに打った文字が、終わりに入らない")
    }

    /// キーボードを出したまま「もとに戻す」を押すと、入力欄も戻り、続けて打っても戻した内容を打ち消さない。
    ///
    /// 回帰テスト: 打っている最中は外からの変化を入力欄へ合わせていなかったので、入力欄に戻す前の
    /// 文字が残り、次の1文字でそれが丸ごと書き戻されていた
    @MainActor
    func testUndoWhileTypingIsNotOverwritten() throws {
        let app = launchApp(clipCount: 1)
        let textView = app.textViews.firstMatch
        textView.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.typeText("abc")

        // 続けて打った文字は0.9秒以内なら1回の「もとに戻す」にまとまるが、シミュレータが重いと
        // 間が空いて、最後の1文字ぶんだけが戻ることもある。どちらでも、入力欄は戻した内容に
        // 合わせ直されて、「abc」より短くなっていること
        app.buttons["もとに戻す"].tap()
        XCTAssertTrue(
            waitUntil(timeout: 3) { (textView.value as? String ?? "abc").count < 3 },
            "もとに戻しても入力欄が古い文字のまま（\(textView.value ?? "")）"
        )
        let afterUndo = textView.value as? String ?? ""
        XCTAssertTrue("abc".hasPrefix(afterUndo), "もとに戻した先が打った文字の途中ではない（\(afterUndo)）")

        app.typeText("d")
        XCTAssertEqual(textView.value as? String, afterUndo + "d", "もとに戻した内容が次の1文字で打ち消された")
    }

    /// キーボードを出したまま別のクリップを選ぶと、入力欄はそのクリップの頭の区間へ合わせ直され、
    /// 打った文字はそこへ入る。
    ///
    /// 回帰テスト: 打っている間はクリップが変わっても合わせ直していなかったので、編集中の区間の文字が
    /// 2本で同じ（どちらも未入力）だと前のクリップの区間の番号のまま残り、2本目の2区間目に入っていた
    @MainActor
    func testSwitchingClipsWhileTypingEditsTheNewClipsFirstSegment() throws {
        let app = launchApp(clipCount: 2, clipSeconds: 4)
        let waveform = app.otherElements["波形。トリム範囲とひとことの区切りを調整できます"]
        XCTAssertTrue(waveform.waitForExistence(timeout: 10), "波形が見つからない")
        let splitButton = app.buttons["ここでひとことを分割（動画は切りません）"]
        // 波形の横の位置（つまみから離れたところ）をタップして、その位置へ頭出しする
        func seek(to fraction: CGFloat) {
            waveform.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5)).tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }

        // 2本とも真ん中で2区間に分ける（どちらの区間も未入力のまま）
        for index in [2, 1] {
            app.buttons["\(index)本目のクリップ"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            seek(to: 0.5)
            splitButton.tap()
            XCTAssertTrue(
                app.staticTexts["／2 区間目を編集中"].waitForExistence(timeout: 3), "\(index)本目を分割できなかった"
            )
        }

        // 1本目の2区間目を打ち始めた状態で、2本目を選んで打つ
        seek(to: 0.85)
        let textView = app.textViews.firstMatch
        textView.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["2本目のクリップ"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        app.typeText("X")
        app.buttons["keyboardDone"].tap()

        // 2本目の頭の区間に入っていること（終わりの区間は空のまま）
        seek(to: 0.85)
        XCTAssertTrue(
            waitUntil(timeout: 3) { (textView.value as? String ?? "") != "X" },
            "2本目の終わりの区間に入った（前のクリップで編集していた区間の番号のまま）"
        )
        seek(to: 0.15)
        XCTAssertTrue(
            waitUntil(timeout: 3) { (textView.value as? String) == "X" },
            "2本目の頭の区間に入っていない（\(textView.value ?? "")）"
        )
    }

    /// クリップが無いとき、ひとこと欄を触ってもキーボードは開かない（打った文字の行き先が無い）
    @MainActor
    func testHitokotoIsNotEditableWithoutClips() throws {
        let app = launchApp(clipCount: 0)

        let textView = app.textViews.firstMatch
        XCTAssertTrue(textView.waitForExistence(timeout: 10), "ひとこと欄が見つからない")
        textView.tap()

        XCTAssertFalse(
            app.keyboards.firstMatch.waitForExistence(timeout: 2),
            "クリップが無いのにキーボードが開いた"
        )
    }

    /// 見えているタイルを押しても、タイムラインは横に動かない。はみ出しているタイルは見える位置まで送る。
    ///
    /// 回帰テスト: 選ぶたびにそのタイルを中央まで送っていたので、見えているタイルを押しただけで
    /// 並びが動き、続けて押そうとした指の下のタイルが入れ替わっていた（Android f12806b）
    @MainActor
    func testSelectingAVisibleTileDoesNotScrollTheTimeline() throws {
        let app = launchApp(clipCount: 8)

        let second = app.buttons["2本目のクリップ"]
        XCTAssertTrue(second.waitForExistence(timeout: 10))
        let before = second.frame
        second.tap()
        // 選択の反映とスクロールのアニメーションを待つ
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(second.frame.minX, before.minX, accuracy: 1, "見えているタイルを押したら並びが動いた")

        // 画面の右にはみ出しているタイルは、押すと全部見える位置まで送られる
        let window = app.windows.firstMatch.frame
        let last = app.buttons["8本目のクリップ"]
        XCTAssertTrue(last.exists)
        // iPadのように広い画面では8本とも収まり、はみ出すタイルが無い。その場合は後半を確かめられない
        guard last.frame.maxX > window.maxX else { return }
        // 画面外のタイルは押せないので、見えている端のタイルを順に押して送っていく
        for index in 3...8 {
            app.buttons["\(index)本目のクリップ"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTAssertLessThanOrEqual(last.frame.maxX, window.maxX + 1, "選んだタイルが画面外のまま")
        attachScreenshot(app, name: "timeline_after_selecting_last")
    }
}
