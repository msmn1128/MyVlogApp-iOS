import XCTest

/// 端末の文字サイズ設定（Dynamic Type）を最大にしても、主要な操作が破綻しないこと。
///
/// 以前は画面の文字が全部固定ptで、設定を上げても一切大きくならなかった
/// （`.font(.system(size:))` が38箇所、`relativeTo:`/`ScaledMetric` はゼロ）。
/// いまは `vlogFont`（VlogTypography.swift）と `@ScaledMetric` で追従させている。
///
/// ⚠️ プレビューの焼き込み文字（ひとこと・撮影時刻）だけは意図的に固定のまま。
/// あれは書き出し映像と数式レベルで一致していないといけないので、
/// 文字サイズ設定で変わってはいけない（PreviewView / VlogLayout）。
final class DynamicTypeUITests: XCTestCase {

    /// アクセシビリティの最大サイズ
    private let largestSize = "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 最大サイズでも、主要な操作が画面に出ていて押せる
    @MainActor
    func testMainControlsRemainUsableAtLargestTextSize() throws {
        let app = launchApp(clipCount: 1, contentSizeCategory: largestSize)

        // 見出しとボタンが消えたり潰れたりしていない
        XCTAssertTrue(app.staticTexts["タイムライン"].exists, "タイムラインの見出しが出ていない")
        XCTAssertTrue(app.staticTexts["ひとこと"].exists, "ひとことの見出しが出ていない")

        let addButton = app.buttons["動画を追加"]
        XCTAssertTrue(addButton.exists && addButton.isHittable, "「動画を追加」が押せない")

        let exportButton = app.descendants(matching: .any)["書き出し"].firstMatch
        XCTAssertTrue(exportButton.exists && exportButton.isHittable, "「書き出し」が押せない")

        // 操作バーは右端（よく使う分割）が見えた状態から始まる。そのボタンも、枠ごと伸びて
        // 押せる状態を保っているか
        let split = app.buttons["ここでひとことを分割（動画は切りません）"]
        XCTAssertTrue(split.exists && split.isHittable, "操作バーのボタンが押せない")

        attachScreenshot(app, name: "largest_text_size")
    }

    /// 操作バーは横スクロールで、既定サイズでも全部のボタンは画面に収まりきらない。
    /// 大事なのは「最大サイズにしたせいで届かなくなっていない」ことなので、
    /// 既定サイズと突き合わせて確かめる（片方だけ見ても良し悪しが判断できない）。
    @MainActor
    func testOperationBarIsNoWorseAtLargestTextSize() throws {
        let splitLabel = "ここでひとことを分割（動画は切りません）"

        let standard = launchApp(clipCount: 1)
        let standardHittable = standard.buttons[splitLabel].isHittable
        standard.terminate()

        let largest = launchApp(clipCount: 1, contentSizeCategory: largestSize)
        let split = largest.buttons[splitLabel]

        XCTAssertTrue(split.exists, "最大サイズで分割ボタンが画面階層から消えた")
        if standardHittable {
            XCTAssertTrue(
                split.isHittable,
                "既定サイズでは押せるのに、最大サイズでは押せなくなっている"
            )
        }
    }

    /// 最大サイズでも、保存ダイアログの中身が収まって操作できる
    @MainActor
    func testSavedProjectsDialogIsUsableAtLargestTextSize() throws {
        let app = launchApp(clipCount: 1, contentSizeCategory: largestSize)

        app.buttons["編集内容の保存と読み出し"].tap()

        XCTAssertTrue(
            app.staticTexts["編集内容の保存"].waitForExistence(timeout: 5),
            "保存ダイアログが出なかった"
        )
        let save = app.buttons["この内容を保存"]
        XCTAssertTrue(save.exists && save.isHittable, "「この内容を保存」が押せない")
        let close = app.buttons["閉じる"]
        XCTAssertTrue(close.exists && close.isHittable, "「閉じる」が押せない")

        attachScreenshot(app, name: "largest_text_size_save_dialog")
        close.tap()
    }

    /// 文字サイズ設定を変えても、プレビューの焼き込み文字は動かない。
    ///
    /// ここが動いてしまうと、画面で見た位置と書き出した動画の位置がずれる
    /// （ExportWorker+Drawing と VlogLayout.hitokotoBlockTop で合わせてある計算が崩れる）。
    /// プレビュー領域の大きさが両方の設定で同じであることをもって、
    /// 中の焼き込み文字がレイアウトに影響していない＝スケールしていないことを確かめる。
    @MainActor
    func testPreviewIsNotAffectedByTextSize() throws {
        let standard = launchApp(clipCount: 1)
        let standardFrame = preview(in: standard).frame
        standard.terminate()

        let largest = launchApp(clipCount: 1, contentSizeCategory: largestSize)
        let largestFrame = preview(in: largest).frame

        XCTAssertEqual(
            standardFrame.width, largestFrame.width, accuracy: 1,
            "文字サイズ設定でプレビューの幅が変わっている（焼き込み文字がスケールしている疑い）"
        )
        XCTAssertEqual(
            standardFrame.height, largestFrame.height, accuracy: 1,
            "文字サイズ設定でプレビューの高さが変わっている（焼き込み文字がスケールしている疑い）"
        )
    }
}
