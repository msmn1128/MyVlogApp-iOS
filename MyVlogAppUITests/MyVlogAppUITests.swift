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
        XCTAssertGreaterThan(last.frame.maxX, window.maxX, "8本目が最初から見えている（テストの前提が崩れた）")
        // 画面外のタイルは押せないので、見えている端のタイルを順に押して送っていく
        for index in 3...8 {
            app.buttons["\(index)本目のクリップ"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        XCTAssertLessThanOrEqual(last.frame.maxX, window.maxX + 1, "選んだタイルが画面外のまま")
        attachScreenshot(app, name: "timeline_after_selecting_last")
    }
}
