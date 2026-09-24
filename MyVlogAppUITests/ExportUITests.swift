import XCTest

/// 書き出しの入口まわり。写真ライブラリへの保存まで通すと権限ダイアログが絡んで
/// 不安定になるため、ここでは「始まること」「進捗が出ること」「中止できること」までを見る。
///
/// 長押し（タイトルカードなし）の経路はXCUITestからは再現できない。同じビューに
/// onTapGesture と onLongPressGesture が同居しており、press(forDuration:) が
/// タップとして解決されてしまうため（アプリ側の不具合ではない）。そちらは実機確認に委ねる。
final class ExportUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 操作バーの「書き出し」。タイトル作成ダイアログにも同じラベルのボタンがあるので、
    /// ダイアログを開く前に取得すること（ダイアログ側は識別子 confirmExport で区別する）
    @MainActor
    private func exportButton(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["書き出し"].firstMatch
    }

    @MainActor
    private func exportProgress(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["exportProgress"].firstMatch
    }

    /// クリップが1本も無いときは書き出しボタンが無効で、押しても何も始まらない
    @MainActor
    func testExportWithoutClipsDoesNotStart() throws {
        let app = launchApp(clipCount: 0)

        let button = exportButton(in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 10), "書き出しボタンが見つからない")
        // 見た目（primaryPillの減光）だけでなく、実際に無効になっていること。
        // VoiceOverから押せてしまわないための.disabled()が効いているかもここで見る
        XCTAssertFalse(button.isEnabled, "クリップが無いのに書き出しボタンが有効になっている")

        if button.isHittable { button.tap() }

        XCTAssertFalse(
            exportProgress(in: app).waitForExistence(timeout: 3),
            "クリップが無いのに書き出しが始まってしまった"
        )
    }

    /// タップするとタイトル作成ダイアログが出る（長押しとの出し分け）
    @MainActor
    func testExportTapOpensTitleDialog() throws {
        let app = launchApp(clipCount: 1)

        exportButton(in: app).tap()

        XCTAssertTrue(
            app.staticTexts["タイトル作成"].waitForExistence(timeout: 10),
            "タイトル作成ダイアログが出なかった"
        )
        attachScreenshot(app, name: "title_dialog")
    }

    /// タイトルの自由入力は、打った内容がそのまま残り、行が増えれば入力欄も伸びる。
    ///
    /// 回帰テスト（入力が残ること）: SwiftUI標準のTextFieldがこの環境で入力を保持できず、
    /// UITextView直結（GrowingTextView）に置き換えた経緯がある。
    /// 回帰テスト（伸びること）: 高さを1行ぶんで固定していたため、書き出し側
    /// （ExportWorker+TitleCard）が複数行のタイトルに対応しているのに、
    /// 入力欄では2行目以降が見えなかった。
    @MainActor
    func testTitleInputKeepsTextAndGrows() throws {
        let app = launchApp(clipCount: 1)

        exportButton(in: app).tap()
        let field = app.textViews["titleTextField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "タイトルの入力欄が見つからない")

        let heightWhenEmpty = field.frame.height
        field.tap()
        // 1行に収まらない長さを打って、折り返しで行数が増えるようにする
        field.typeText("なつやすみのおもいでとかぞくりょこうのきろく2026")

        XCTAssertEqual(
            field.value as? String, "なつやすみのおもいでとかぞくりょこうのきろく2026",
            "打った内容が入力欄に残っていない"
        )
        XCTAssertGreaterThan(
            field.frame.height, heightWhenEmpty,
            "行が増えたのに入力欄が伸びていない（高さ=\(field.frame.height)）"
        )
        attachScreenshot(app, name: "title_dialog_multiline")
    }

    /// ダイアログで確定すると書き出しが始まり、進捗が出て、中止できる。
    ///
    /// 回帰テスト（中止）: 中止すると一時ファイルを片付けたうえで、中止したことを通知する。
    @MainActor
    func testExportShowsProgressAndCanBeCancelled() throws {
        // クリップは長めにする。既定の2秒1本だと、結合が速くなってから（11f19ec）、「中止」を押す前に
        // 書き出しが終わることがあり、押したつもりの位置にある「書き出し」をもう一度押していた
        let app = launchApp(clipCount: 1, clipSeconds: 30)

        exportButton(in: app).tap()
        let confirm = app.descendants(matching: .any)["confirmExport"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "タイトル作成ダイアログが出なかった")
        confirm.tap()

        XCTAssertTrue(
            exportProgress(in: app).waitForExistence(timeout: 20),
            "書き出しの進捗が出なかった"
        )
        attachScreenshot(app, name: "export_in_progress")

        // 書き出し中は「書き出し」が「中止」へ入れ替わる
        let cancel = app.descendants(matching: .any)["中止"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), "中止ボタンが出なかった")
        cancel.tap()

        XCTAssertTrue(
            app.staticTexts["書き出しを中止しました"].waitForExistence(timeout: 20),
            "中止したことが通知されなかった"
        )
        attachScreenshot(app, name: "export_cancelled")
    }
}
