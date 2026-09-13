//
//  MyVlogAppUITests.swift
//  MyVlogAppUITests
//

import XCTest

final class MyVlogAppUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 起動直後の主要要素と、追加メニューが開けることを確認するスモークテスト。
    /// PHPickerViewControllerは別プロセスで動くため、動画選択そのものはXCUITestの
    /// スコープ外（app.cellsで拾えない）——そこから先は手動確認に委ねる。
    @MainActor
    func testHomeScreenAndAddMenu() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["タイムライン"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ひとこと"].waitForExistence(timeout: 5))
        // 前回の自動保存でクリップが残っている場合と、空の場合の両方がありうる。

        let addButton = app.buttons["動画を追加"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))
        addButton.tap()

        let photoLibraryItem = app.buttons["フォトライブラリ"]
        let fileItem = app.buttons["ファイルから選択"]
        XCTAssertTrue(photoLibraryItem.waitForExistence(timeout: 5))
        XCTAssertTrue(fileItem.exists)

        // メニューを閉じる（画面外をタップ）
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)).tap()

        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        attachment.name = "home_screen"
        add(attachment)
    }

    /// TEMP QA: キーボードのスワイプダウンで閉じるかどうかを確認する。
    @MainActor
    func testKeyboardSwipeDown() throws {
        let app = XCUIApplication()
        app.launch()

        let textView = app.textViews.firstMatch
        XCTAssertTrue(textView.waitForExistence(timeout: 10))
        textView.tap()

        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "キーボードが開かなかった")

        let before = app.screenshot()
        add(XCTAttachment(screenshot: before))

        // キーボード上端からスワイプダウン
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        start.press(forDuration: 0.05, thenDragTo: end)

        sleep(1)
        let after = app.screenshot()
        let attachment = XCTAttachment(screenshot: after)
        attachment.lifetime = .keepAlways
        attachment.name = "after_swipe_down"
        add(attachment)

        // キーボードがまだあるかどうかをログに残す（成否はスクリーンショットで人間が判断）
        print("keyboard exists after swipe: \(app.keyboards.firstMatch.exists)")
    }
}
