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
        let app = launchApp(clipCount: 0)

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
}
