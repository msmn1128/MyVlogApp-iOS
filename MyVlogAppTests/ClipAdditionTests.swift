import Testing
@testable import MyVlogApp

/// 動画を追加するときの振り分け（planAddition）。Android: ClipAdditionTest
@Suite("動画を追加するときの振り分け")
struct ClipAdditionTests {

    private func plan(
        _ requested: [String], existing: Set<String> = [], currentCount: Int = 0, limit: Int = 100,
        keys: [String: String?] = [:]
    ) -> (toLoad: [String], alreadyAdded: Int, overLimit: Int) {
        let result = planAddition(
            requested: requested, existing: existing, currentCount: currentCount, limit: limit
        ) { keys[$0] ?? $0 }
        return (result.toLoad, result.alreadyAdded, result.overLimit)
    }

    @Test("新しい動画は選んだ順に読み込む")
    func newVideosAreLoadedInTheOrderTheyWereChosen() {
        let result = plan(["c", "a", "b"])
        #expect(result.toLoad == ["c", "a", "b"])
        #expect(result.alreadyAdded == 0 && result.overLimit == 0)
    }

    @Test("タイムラインにある動画は読まずに外して数える")
    func videosAlreadyInTheTimelineAreSkippedAndCounted() {
        let result = plan(["a", "b"], existing: ["a"], currentCount: 1)
        #expect(result.toLoad == ["b"])
        #expect(result.alreadyAdded == 1)
    }

    @Test("同じ動画を2回選んでも「追加済み」とは数えない")
    func theSameVideoChosenTwiceIsNotReportedAsAlreadyAdded() {
        let result = plan(["a", "a"])
        #expect(result.toLoad == ["a"])
        #expect(result.alreadyAdded == 0)
    }

    @Test("上限を超える分は読まずに断る")
    func videosBeyondTheLimitAreRefusedWithoutLoading() {
        // 残り2本の枠に4本 → 選んだ順の先頭2本だけ読み、2本は読まずに断る
        let result = plan(["a", "b", "c", "d"], currentCount: 8, limit: 10)
        #expect(result.toLoad == ["a", "b"])
        #expect(result.overLimit == 2)
    }

    @Test("いっぱいのタイムラインには何も読まない")
    func aFullTimelineLoadsNothing() {
        let result = plan(["x", "a", "b"], existing: ["x"], currentCount: 10, limit: 10)
        #expect(result.toLoad.isEmpty)
        #expect(result.alreadyAdded == 1 && result.overLimit == 2)
    }

    @Test("鍵の取れない動画は重複を判定できないので読み込む")
    func videosWithoutAKeyAreAlwaysLoaded() {
        let result = plan(["p1", "p2"], existing: ["p1"], keys: ["p1": nil, "p2": nil])
        #expect(result.toLoad == ["p1", "p2"])
        #expect(result.alreadyAdded == 0)
    }
}
