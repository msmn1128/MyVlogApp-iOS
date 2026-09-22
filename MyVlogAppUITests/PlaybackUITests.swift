import XCTest

/// 再生まわりの振る舞い。純粋関数（PlaybackRulesTests）では確かめられない、
/// AVPlayerとトリム終端の監視を含めた実際の動きを見る。
final class PlaybackUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 再生位置が動かなくなるまで待つ（テスト用クリップは1本2秒）。
    ///
    /// 「2秒ぶん動かない」まで求めるのは、クリップが切り替わる瞬間（次のクリップの
    /// 読み込み待ち）にも位置が一時的に止まるため。そこを「終わった」と取り違えると、
    /// 連続再生のテストが途中の状態を見て誤って通ってしまう。
    @MainActor
    private func waitForPlaybackToStop(in app: XCUIApplication, timeout: TimeInterval = 20) {
        let pollInterval: TimeInterval = 0.5
        let stableRequired = 4
        var previous: Int64 = -1
        var stableCount = 0
        _ = waitUntil(timeout: timeout, pollInterval: pollInterval) {
            let current = playheadMs(in: app) ?? -1
            stableCount = (current == previous && current > 0) ? stableCount + 1 : 0
            previous = current
            return stableCount >= stableRequired
        }
    }

    /// 終端で止まったあと再生を押すと、頭出しされてから再生が始まる。
    ///
    /// 回帰テスト: 以前は頭出しせずにそのまま再生していたため、トリム終端の監視が
    /// 直ちにまた止めてしまい、「再生ボタンが効かない」ように見えていた。
    @MainActor
    func testPlayingFromTheEndSeeksBackToStart() throws {
        let app = launchApp(clipCount: 1)
        setContinuousPlay(false, in: app)

        let preview = preview(in: app)
        preview.tap()                      // 再生開始
        waitForPlaybackToStop(in: app)     // クリップの終わりで自動的に止まる

        let atEnd = playheadMs(in: app) ?? 0
        XCTAssertGreaterThan(atEnd, 1_000, "クリップの終わりまで再生されなかった（位置=\(atEnd)）")
        attachScreenshot(app, name: "stopped_at_end")

        // ここで再生を押す。頭出しされて再生が始まるはず
        preview.tap()
        let restarted = waitUntil(timeout: 6) { (playheadMs(in: app) ?? atEnd) < atEnd / 2 }

        XCTAssertTrue(
            restarted,
            "終端から再生を押しても頭出しされなかった（位置=\(playheadMs(in: app) ?? -1)）"
        )
        attachScreenshot(app, name: "restarted_from_beginning")
    }

    /// トリムプリセット（2s）で切ったら、再生もその位置で止まる。
    ///
    /// 回帰テスト: AVPlayerのトリム終端の監視（boundaryObserver）を張り直していたのは
    /// 波形のドラッグ経路だけで、プリセットともとに戻す/やり直しからは更新していなかった。
    /// そのためクリップを2秒に切っても監視は元の長さのまま残り、最後まで再生されていた。
    /// いまはContentViewがselectedClip.trimBoundsのonChangeで中継している。
    @MainActor
    func testTrimPresetStopsPlaybackAtNewEnd() throws {
        // 「2sに切った」と「元のまま」を区別できるよう、元の長さを4秒にして起動する
        let app = launchApp(clipCount: 1, clipSeconds: 4)
        setContinuousPlay(false, in: app)

        let preset = app.buttons["2s"]
        XCTAssertTrue(preset.waitForExistence(timeout: 10), "トリムプリセットのボタンが見つからない")
        preset.tap()

        preview(in: app).tap()             // 再生開始
        waitForPlaybackToStop(in: app, timeout: 20)

        let stopped = playheadMs(in: app) ?? -1
        XCTAssertGreaterThan(stopped, 1_000, "2秒ぶんも再生されていない（位置=\(stopped)）")
        XCTAssertLessThan(
            stopped, 2_500,
            "2sに切ったのに、切る前の終端（約4000ms）まで再生されている（位置=\(stopped)）"
        )
        attachScreenshot(app, name: "stopped_at_trim_preset_end")
    }

    /// 選択中のクリップを削除したら、プレビューは次のクリップへ切り替わる。
    ///
    /// 回帰テスト: 再生の読み込みをstore.selectedIndexの変化だけで駆動していたため、
    /// 「番号は同じまま中身だけ入れ替わる」削除（[A,B]のAを消すとindex 0がBになる）では
    /// 読み込み直しが起きず、消したはずのクリップがAVPlayerに載ったままだった。
    /// いまはselectedClip?.idで駆動している。
    @MainActor
    func testDeletingSelectedClipLoadsTheNextOne() throws {
        let app = launchApp(clipCount: 2)
        setContinuousPlay(false, in: app)

        // 1本目を終わりまで再生して、再生位置を0から十分離しておく
        preview(in: app).tap()
        waitForPlaybackToStop(in: app)
        let beforeDelete = playheadMs(in: app) ?? -1
        XCTAssertGreaterThan(beforeDelete, 1_000, "1本目が最後まで再生されなかった（位置=\(beforeDelete)）")

        let trash = app.buttons["選択中のクリップを削除"]
        XCTAssertTrue(trash.waitForExistence(timeout: 5), "削除ボタンが見つからない")
        trash.tap()

        // 次のクリップが読み込まれ、その頭（0ms付近）から始まる。
        // 読み込み直しが起きていなければ、消したクリップの終端の位置のまま止まっている
        XCTAssertTrue(
            waitUntil(timeout: 10) { (playheadMs(in: app) ?? beforeDelete) < 500 },
            "削除しても再生位置が動いていない（消したクリップが載ったまま。位置=\(playheadMs(in: app) ?? -1)）"
        )
        attachScreenshot(app, name: "after_deleting_selected_clip")
    }

    /// 連続再生オンで最後のクリップまで再生したら、先頭へ戻らずそこで止まる。
    ///
    /// 回帰テスト: 以前は先頭へ戻して一時停止していた（さらにその前は先頭へ戻って
    /// 再生を続ける無限ループだった）。Android版が「そこで止める」へ変わったのに合わせた。
    @MainActor
    func testContinuousPlayStopsAtTimelineEndWithoutRewinding() throws {
        let app = launchApp(clipCount: 2)
        setContinuousPlay(true, in: app)

        preview(in: app).tap()
        // 2本ぶん（2秒 × 2）再生され、最後のクリップの終わりで止まるまで待つ
        waitForPlaybackToStop(in: app, timeout: 25)

        let stopped = playheadMs(in: app) ?? -1
        XCTAssertGreaterThan(
            stopped, 1_000,
            "先頭へ巻き戻ってしまっている（位置=\(stopped)）。最後のクリップの終わりで止まるべき"
        )

        // 止まったあと勝手に動き出さない（無限ループしていない）ことも確かめる
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let after = playheadMs(in: app) ?? -1
        XCTAssertEqual(after, stopped, "止まったはずなのに再生が続いている")
        attachScreenshot(app, name: "stopped_at_timeline_end")
    }
}
