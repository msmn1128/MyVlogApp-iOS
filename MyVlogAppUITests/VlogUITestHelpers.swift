import XCTest

// =====================================================================================
// 再生・書き出しのUIテストで共通して使う起動と待ち合わせ。
//
// 動画の取り込みはシステムのフォトピッカー（別プロセス）を通るためXCUITestからは
// 操作できない。代わりにアプリ側の起動引数でテスト用のクリップを入れてもらう
// （MyVlogApp/UITestSupport.swift）。保存先も起動ごとに空の領域へ切り替わるので、
// テストはシミュレータに残っている実際の編集内容に影響されない。
//
// 基底クラスではなくextensionにしてあるのは、テストメソッドを持たない
// XCTestCaseのサブクラスがテスト一覧に「未実行」として並んでしまうため。
// =====================================================================================

extension XCTestCase {

    /// テスト用クリップを`clipCount`本入れた状態でアプリを起動する。
    /// クリップは無音で、タイムラインにはその本数のタイルが並ぶ。
    ///
    /// - Parameter clipSeconds: 1本の長さ（秒）。既定（nil）は2秒。トリムのように
    ///   「切った長さと元の長さの違い」を見たいテストだけ長くする。
    /// - Parameter contentSizeCategory: 端末の文字サイズ設定（Dynamic Type）。
    ///   既定（nil）は端末のまま。最大サイズでレイアウトが破綻しないかを見るテストで使う。
    @MainActor
    func launchApp(
        clipCount: Int, clipSeconds: Double? = nil, contentSizeCategory: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestSeedClips", "\(clipCount)"]
        if let clipSeconds {
            app.launchArguments += ["-UITestSeedClipSeconds", "\(clipSeconds)"]
        }
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()

        XCTAssertTrue(
            app.staticTexts["タイムライン"].waitForExistence(timeout: 20),
            "アプリが起動しなかった"
        )
        guard clipCount > 0 else { return app }

        // クリップの生成（AVAssetWriter）と投入が終わるまで待つ。
        // 分割ボタンは選択中のクリップがあるときだけ有効になるので、これを目印にする
        let splitButton = app.buttons["ここでひとことを分割（動画は切りません）"]
        XCTAssertTrue(
            waitUntil(timeout: 40) { splitButton.exists && splitButton.isEnabled },
            "テスト用クリップが入らなかった"
        )
        return app
    }

    /// プレビュー領域。タップで再生/一時停止、accessibilityValueが再生位置(ms)
    @MainActor
    func preview(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["preview"].firstMatch
    }

    /// いまの再生位置（ミリ秒）。読めなければnil。
    ///
    /// プレビュー本体の読み上げは利用者向けに「0:01」という形にしてあるので、
    /// テストはミリ秒の生値を持つ専用の目印（PlayheadProbe、DEBUGのみ）から読む。
    ///
    /// アプリ側は`"\(currentTimeMs)"`をそのまま渡しているが、アクセシビリティ層が
    /// 数字だけの値を桁区切り付き（"1,000"）へ整形して返してくる。区切り記号は
    /// ロケールによって変わるので、数字以外を落としてから読む。
    @MainActor
    func playheadMs(in app: XCUIApplication) -> Int64? {
        let element = app.descendants(matching: .any)["playheadMs"].firstMatch
        guard element.exists else { return nil }
        let raw: String
        switch element.value {
        case let text as String: raw = text
        case let number as NSNumber: raw = number.stringValue
        default: return nil
        }
        let digits = raw.filter(\.isNumber)
        return digits.isEmpty ? nil : Int64(digits)
    }

    /// `condition`が真になるまで最大`timeout`秒待つ。XCUIElementの待機APIでは
    /// 表現できない条件（再生位置が進んだ、など）に使う
    @MainActor
    @discardableResult
    func waitUntil(timeout: TimeInterval, pollInterval: TimeInterval = 0.2,
                   _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return condition()
    }

    /// 連続再生トグル。状態は読み上げの値（オン/オフ）に入っている（OperationBar.swift）
    @MainActor
    func setContinuousPlay(_ enabled: Bool, in app: XCUIApplication) {
        let label  = "連続再生（オンなら終わったら次のクリップへ、オフならクリップの終わりで止まります）"
        let target = enabled ? "オン" : "オフ"
        let toggle = app.descendants(matching: .any)[label].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "連続再生トグルが見つからない")
        if toggle.value as? String == target { return }
        toggle.tap()
        // シミュレータが重いと、起動直後のタップが届かないことがある。変わっていなければもう一度押す
        if !waitUntil(timeout: 3, { toggle.value as? String == target }) {
            toggle.tap()
        }
        XCTAssertTrue(
            waitUntil(timeout: 5) { toggle.value as? String == target },
            "連続再生を\(target)にできなかった"
        )
    }

    @MainActor
    func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.lifetime = .keepAlways
        attachment.name = name
        add(attachment)
    }
}
