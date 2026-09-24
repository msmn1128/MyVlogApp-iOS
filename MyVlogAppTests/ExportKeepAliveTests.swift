import Foundation
import Testing
@testable import MyVlogApp

// =====================================================================================
// 書き出しをアプリを離れても続けるための仕組み（ExportKeepAlive）の流れ。
//
// シミュレータはシステムの「続ける作業」の申し込みを必ず断るので、受け付けられたときの流れは
// 実機でしか動かない。システムの部分を偽物に差し替えて、どの順で何が起きても正しく終えるかを確かめる。
// =====================================================================================

/// 偽物の作業。何回・どの結果で終えたかを覚える
private final class FakeTask: ContinuedProcessingTaskHandle {
    let title = "VLOGを書き出し中"
    let progress = Progress()
    var expirationHandler: (() -> Void)?
    private(set) var subtitles: [String] = []
    private(set) var completions: [Bool] = []

    func updateTitle(_ title: String, subtitle: String) { subtitles.append(subtitle) }
    func setTaskCompleted(success: Bool) { completions.append(success) }
}

/// 偽物の申し込み。受け付けるかどうかと、作業を始めさせる合図をテストから操る
private final class FakeScheduler: ContinuedProcessingScheduling {
    var accepts = true
    private(set) var titles: [String] = []
    private(set) var pendingStarts: [(ContinuedProcessingTaskHandle) -> Void] = []

    func submit(title: String, subtitle: String, onStart: @escaping (ContinuedProcessingTaskHandle) -> Void) -> Bool {
        titles.append(title)
        guard accepts else { return false }
        pendingStarts.append(onStart)
        return true
    }

    /// 申し込んだ作業を始めさせる（何番目の申し込みか）
    func start(_ index: Int = 0, with task: FakeTask) { pendingStarts[index](task) }
}

/// 偽物の延長
private final class FakeExtension: BackgroundExtending {
    private(set) var begun = 0
    private(set) var ended = 0
    private var onExpired: (() -> Void)?

    func begin(name: String, onExpired: @escaping () -> Void) {
        begun += 1
        self.onExpired = onExpired
    }
    func end() { ended += 1 }
    func expire() { onExpired?() }
}

/// 作業の開始は画面と同じスレッドへ移ってから扱われる。その移りが済むのを待つ
@MainActor
private func settle() async {
    for _ in 0..<5 { await Task.yield() }
}

@MainActor
@Suite("書き出しをアプリを離れても続ける仕組み")
struct ExportKeepAliveTests {

    @Test("受け付けられたら延長は使わず、進み具合と工程を作業へ伝え、終わったら成功で終える")
    func acceptedTaskReportsProgressAndCompletes() async {
        let scheduler = FakeScheduler(), fallback = FakeExtension(), task = FakeTask()
        let keepAlive = ExportKeepAlive(scheduler: scheduler, fallback: fallback)

        keepAlive.begin(title: "VLOGを書き出し中") {}
        #expect(fallback.begun == 0, "受け付けられたのに延長も使っている")

        scheduler.start(with: task)
        await settle()
        #expect(task.progress.totalUnitCount == ExportKeepAlive.progressUnits)

        keepAlive.update(progress: 0.5, message: "クリップ 2/4 を処理中...")
        #expect(task.progress.completedUnitCount == ExportKeepAlive.progressUnits / 2)
        #expect(task.subtitles.last == "クリップ 2/4 を処理中...")

        keepAlive.end(success: true)
        #expect(task.completions == [true])
    }

    @Test("作業が始まる前に伝えた進み具合は、始まったときにまとめて伝える")
    func progressBeforeStartIsAppliedOnStart() async {
        let scheduler = FakeScheduler(), task = FakeTask()
        let keepAlive = ExportKeepAlive(scheduler: scheduler, fallback: FakeExtension())

        keepAlive.begin(title: "t") {}
        keepAlive.update(progress: 0.25, message: "タイトルを作成中...")
        scheduler.start(with: task)
        await settle()

        #expect(task.progress.completedUnitCount == ExportKeepAlive.progressUnits / 4)
        #expect(task.subtitles.last == "タイトルを作成中...")
    }

    @Test("作業が始まる前に書き出しが終わっていたら、始まった時点でその結果ですぐに終える")
    func taskStartingAfterTheExportFinishedIsCompletedImmediately() async {
        let scheduler = FakeScheduler(), task = FakeTask()
        let keepAlive = ExportKeepAlive(scheduler: scheduler, fallback: FakeExtension())

        keepAlive.begin(title: "t") {}
        keepAlive.end(success: true)
        scheduler.start(with: task)
        await settle()

        #expect(task.completions == [true])
    }

    @Test("打ち切られたら、その場で失敗として終え、書き出しを止めさせる。あとの end で二重に終えない")
    func expirationCompletesOnceAndStopsTheExport() async {
        let scheduler = FakeScheduler(), task = FakeTask()
        let keepAlive = ExportKeepAlive(scheduler: scheduler, fallback: FakeExtension())
        var stopped = 0

        keepAlive.begin(title: "t") { stopped += 1 }
        scheduler.start(with: task)
        await settle()

        task.expirationHandler?()
        #expect(task.completions == [false], "打ち切られたのにその場で終えていない")
        await settle()
        #expect(stopped == 1, "打ち切られたのに書き出しを止めさせていない")

        // 書き出しが止まったあとの後始末で end が呼ばれても、もう終えた作業には伝えない
        keepAlive.end(success: false)
        #expect(task.completions == [false])
        #expect(stopped == 1)
    }

    @Test("前の回に申し込んだ作業が遅れて始まっても、今の回の作業と取り違えない")
    func lateTaskFromThePreviousExportIsNotMixedUp() async {
        let scheduler = FakeScheduler(), oldTask = FakeTask(), newTask = FakeTask()
        let keepAlive = ExportKeepAlive(scheduler: scheduler, fallback: FakeExtension())

        keepAlive.begin(title: "1回目") {}
        keepAlive.end(success: false)          // 1回目は作業が始まる前に中止された
        keepAlive.begin(title: "2回目") {}
        scheduler.start(1, with: newTask)
        scheduler.start(0, with: oldTask)      // 1回目の作業があとから始まった
        await settle()

        #expect(oldTask.completions == [false], "前の回の作業を終えていない")
        keepAlive.update(progress: 0.5, message: "結合中...")
        #expect(newTask.progress.completedUnitCount == ExportKeepAlive.progressUnits / 2)
        #expect(oldTask.progress.completedUnitCount == 0, "前の回の作業に今の回の進み具合を伝えた")
    }

    @Test("断られたら延長を使い、延長を使い切ったら書き出しを止めさせて、延長をその場で返す")
    func rejectedSubmissionFallsBackToTheExtension() {
        let scheduler = FakeScheduler(), fallback = FakeExtension()
        scheduler.accepts = false
        let keepAlive = ExportKeepAlive(scheduler: scheduler, fallback: fallback)
        var stopped = 0

        keepAlive.begin(title: "t") { stopped += 1 }
        #expect(fallback.begun == 1)

        fallback.expire()
        #expect(stopped == 1)
        #expect(fallback.ended == 1, "延長を使い切ったのに返していない（iOSにアプリを終了させられる）")
    }

    @Test("中止（書き出しを止める）だけでは作業を終えず、書き出しが終わった end で終える")
    func cancellingDoesNotCompleteUntilTheExportEnds() async {
        let scheduler = FakeScheduler(), task = FakeTask()
        let keepAlive = ExportKeepAlive(scheduler: scheduler, fallback: FakeExtension())

        keepAlive.begin(title: "t") {}
        scheduler.start(with: task)
        await settle()
        // ExportManager.cancel は書き出しを止めるよう頼むだけで、ExportKeepAlive には触らない。
        // 後始末が終わるまでアプリを止められないよう、作業はまだ終えない
        #expect(task.completions.isEmpty)

        keepAlive.end(success: false)
        #expect(task.completions == [false])
    }
}

/// 進み具合の数字が取れない工程（結合・写真への保存）での進め方（ExportManager.creptProgress）
@Suite("進み具合の数字が取れない工程での進め方")
struct ExportProgressCreepTests {

    @Test("30分続いても、システムへ伝わる数字は毎秒必ず動き、目標は越えない")
    func reportedProgressKeepsMovingForHalfAnHour() {
        // 止まったとみなされないためには、伝わる数字（100万分の1刻み）が動き続ける必要がある。
        // 残りの何割かずつ近づける形では、30秒ほどで伝わる数字が動かなくなっていた
        var previous = Int64(0.6 * Double(ExportKeepAlive.progressUnits))
        for second in 1...1_800 {
            let progress = ExportManager.creptProgress(from: 0.6, toward: 0.84, elapsedSeconds: Double(second))
            let reported = Int64(progress * Double(ExportKeepAlive.progressUnits))
            #expect(reported > previous, "\(second)秒目で伝わる数字が動かなかった")
            #expect(progress < 0.84, "目標を越えた")
            previous = reported
        }
    }

    @Test("はじめは目に見えて進む（20秒で残りの半分）")
    func movesVisiblyAtFirst() {
        #expect(abs(ExportManager.creptProgress(from: 0.6, toward: 0.8, elapsedSeconds: 20) - 0.7) < 0.000_001)
    }

    @Test("目標が今より手前なら動かさない")
    func neverGoesBackwards() {
        #expect(ExportManager.creptProgress(from: 0.9, toward: 0.8, elapsedSeconds: 10) == 0.9)
    }
}
