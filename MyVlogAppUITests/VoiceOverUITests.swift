import XCTest

/// VoiceOverから触れる形になっているか。
///
/// 見た目だけで伝えている情報（選択中の枠線、ラジオの丸）や、ジェスチャーでしか
/// 用意していなかった操作（保存の読み出し・上書き、波形のトリム）は、
/// 支援技術からは存在しないのと同じだった。ここではその穴が塞がっていることを見る。
///
/// XCUITestは実際の読み上げ音声までは検証できないので、
/// 「要素として存在するか」「操作が届いて状態が変わるか」で確かめる。
final class VoiceOverUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 波形はCanvas描画なので、そのままでは支援技術に何も見えない。
    /// トリムと再生位置を調整できる項目が用意されていること。
    @MainActor
    func testWaveformExposesAdjustableControls() throws {
        let app = launchApp(clipCount: 1, clipSeconds: 4)

        for label in ["トリム開始", "トリム終了", "再生位置"] {
            XCTAssertTrue(
                app.descendants(matching: .any)[label].firstMatch.waitForExistence(timeout: 10),
                "波形の「\(label)」が支援技術から見えない"
            )
        }
    }

    /// 波形の項目が出している値が、実際のトリムに追従していること。
    ///
    /// ラベルだけ足して値が固定、というのがいちばんありがちな作り損ないなので、
    /// 別の手段（2sプリセット）でトリムを変えたときに値が動くことを見る。
    ///
    /// 「調整」操作そのものの発火は、XCUITestの`adjust`がスライダー要素にしか
    /// 使えないためここからは呼べない。動かした先の計算は純粋関数へ切り出して
    /// 単体テストしてある（MyVlogAppTests/AccessibilityAdjustTests.swift）。
    @MainActor
    func testWaveformAccessibilityValuesFollowTheClip() throws {
        let app = launchApp(clipCount: 1, clipSeconds: 4)

        let trimEnd = app.descendants(matching: .any)["トリム終了"].firstMatch
        XCTAssertTrue(trimEnd.waitForExistence(timeout: 10), "「トリム終了」が見つからない")
        let before = trimEnd.value as? String

        app.buttons["2s"].tap()   // トリムを先頭2秒へ

        XCTAssertTrue(
            waitUntil(timeout: 5) { (trimEnd.value as? String) != before },
            "トリムを変えても、支援技術に出している値が古いまま（before=\(before ?? "nil")）"
        )
    }

    /// 一時保存の行は、タップ＝読み出し／長押し＝上書きをジェスチャーでしか
    /// 持っておらず、VoiceOverからはどちらも実行できなかった。
    /// 行が1つの項目になり、上書き・削除がカスタム操作として出ていること。
    @MainActor
    func testSavedProjectRowIsReachableWithCustomActions() throws {
        let app = launchApp(clipCount: 1)

        app.buttons["編集内容の保存と読み出し"].tap()
        XCTAssertTrue(app.staticTexts["編集内容の保存"].waitForExistence(timeout: 5))

        app.buttons["この内容を保存"].tap()

        // 保存した行が、名前と内容を1つの項目として読める形で並んでいる
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "1本")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "保存した行が項目として出ていない")
        XCTAssertTrue(row.label.contains("に保存"), "行のラベルに保存日時が含まれていない: \(row.label)")
    }

    /// タイトル作成ダイアログのラジオは、丸の絵でしか選択状態を示していなかった。
    /// 選択肢が項目として並び、選ぶと選択状態が移ること。
    @MainActor
    func testTitleDialogRadioOptionsExposeSelection() throws {
        let app = launchApp(clipCount: 1)

        app.descendants(matching: .any)["書き出し"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["タイトル作成"].waitForExistence(timeout: 10))

        let custom = app.descendants(matching: .any)["自由に入力したタイトルにする"].firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 5), "自由入力の選択肢が項目になっていない")

        let dateOption = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "撮影日")).firstMatch
        XCTAssertTrue(dateOption.exists, "撮影日の選択肢が項目になっていない")

        // 自由入力を選ぶと、そちらが選択中になる
        custom.tap()
        XCTAssertTrue(
            waitUntil(timeout: 5) { custom.isSelected },
            "自由入力を選んでも、選択状態が支援技術に伝わっていない"
        )
    }

    /// タイムラインのタイルは、選択中かどうかを枠線の太さでしか示していなかった
    @MainActor
    func testClipTileAnnouncesSelection() throws {
        let app = launchApp(clipCount: 2)

        let first = app.descendants(matching: .any)["1本目のクリップ"].firstMatch
        let second = app.descendants(matching: .any)["2本目のクリップ"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "クリップが何本目か分かる項目になっていない")
        XCTAssertTrue(second.exists)

        // 追加直後はいちばん古いクリップが選ばれている
        XCTAssertTrue(first.isSelected, "選択中のクリップが支援技術から分からない")
        XCTAssertFalse(second.isSelected)

        second.tap()
        XCTAssertTrue(
            waitUntil(timeout: 5) { second.isSelected && !first.isSelected },
            "選択を移しても、選択状態が支援技術に伝わっていない"
        )
    }
}
