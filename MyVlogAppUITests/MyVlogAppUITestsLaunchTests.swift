//
//  MyVlogAppUITestsLaunchTests.swift
//  MyVlogAppUITests
//
//  Created by 戸田誠大 on 2026/08/26.
//

import XCTest

final class MyVlogAppUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        // 起動引数を付けて使い捨ての保存領域で立ち上げる（UITestSupport.swift）。
        // 付けないとシミュレータに残っている実際の編集内容が写り込み、
        // 起動スクリーンショットが実行のたびに変わってしまう
        let app = XCUIApplication()
        app.launchArguments += ["-UITestSeedClips", "0"]
        app.launch()

        XCTAssertTrue(app.staticTexts["タイムライン"].waitForExistence(timeout: 20), "アプリが起動しなかった")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
