import BackgroundTasks
import Foundation

/// 書き出しを、アプリを離れても続けるための仕組み（Android: VlogExportService をフォアグラウンドサービスにしているのに当たる）。
///
/// iOS 26 以降は `BGContinuedProcessingTask` を使う。書き出しを始めるときにシステムへ申し込むと、
/// アプリを離れても最後まで書き出せ、進み具合がシステムの表示（ロック画面など）に出る。
/// そこから中止されたとき・システムの都合で続けられなくなったときは`onExpired`が呼ばれるので、
/// 書き出しを止める。進み具合を報告し続けないと「止まっている」とみなされて打ち切られるので、
/// 書き出しの進み具合をそのまま渡す（`update`）。
///
/// iOS 26 より前の端末と、申し込みが断られたとき（システムが混んでいる、シミュレータなど）は、
/// これまでどおり `beginBackgroundTask` の延長（約30秒）で動く。延長を使い切ると`onExpired`が呼ばれる。
/// 以前はこちらしか無く、書き出し中にアプリを離れると約30秒で中止されていた。
///
/// システムの部分（申し込み・延長）は差し替えられる形にしてある。シミュレータは申し込みを必ず断るので、
/// 受け付けられたときの流れはテストの偽物でしか動かせないため（ExportKeepAliveTests）。
@MainActor
final class ExportKeepAlive {
    private let scheduler: ContinuedProcessingScheduling
    private let fallback: BackgroundExtending
    private var onExpired: (() -> Void)?

    /// いま動いている作業。申し込んでから実際に始まるまでの間はnil
    private var continuedTask: ContinuedProcessingTaskHandle?
    /// 書き出しの回ごとの番号。前の回に申し込んだ作業があとから始まっても、今の回の作業と取り違えない
    private var generation = 0
    /// 作業が始まる前に書き出しが終わっていたら、始まった時点ですぐに終える
    private var finishedResult: Bool?
    private var latestProgress: Double = 0
    private var latestMessage: String = ""

    /// 進み具合をこの細かさで報告する（100万分の1刻み）。進み具合の数字が取れない工程で少しずつ
    /// 進めるとき（ExportManager.creepProgress）、1回に進む量が小さくなっても伝わる数字が動くよう細かくしてある。
    /// 動かないとシステムから「止まっている」とみなされて打ち切られうる
    nonisolated static let progressUnits: Int64 = 1_000_000

    /// 引数を省くと本物を使う（テストだけが偽物を渡す）。既定値を引数の側に書くと、並行処理の決まり上
    /// 本物を作れる場所の外で作ることになるので、ここで作る
    init(scheduler: ContinuedProcessingScheduling? = nil, fallback: BackgroundExtending? = nil) {
        self.scheduler = scheduler ?? SystemContinuedProcessingScheduler()
        self.fallback = fallback ?? BackgroundTaskGuard()
    }

    /// - Parameters:
    ///   - title: システムの表示に出す題（例「VLOGを書き出し中」）
    ///   - onExpired: 続けられなくなったとき（システムの表示から中止された・時間切れ）に呼ぶ。書き出しを止めること
    func begin(title: String, onExpired: @escaping () -> Void) {
        generation += 1
        let current = generation
        self.onExpired = onExpired
        finishedResult = nil
        continuedTask = nil
        latestProgress = 0
        latestMessage = ""

        let accepted = scheduler.submit(title: title, subtitle: "準備中...") { [weak self] task in
            // システムの作業は別のスレッドで始まるので、画面と同じスレッドへ移ってから扱う
            Task { @MainActor [weak self] in
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task, generation: current)
            }
        }
        if accepted { return }
        fallback.begin(name: "VlogExport") { [weak self] in
            MainActor.assumeIsolated {
                self?.expire()
                // 延長を使い切ったら、その場で返す。返さないとiOSにアプリごと終了させられる
                // （書き出しの後始末は間に合わなくても、次の起動時の掃除で消える）
                self?.fallback.end()
            }
        }
    }

    /// 進み具合と、いまの工程（「クリップ 2/5 を処理中...」など）を伝える
    func update(progress: Double, message: String) {
        latestProgress = max(0, min(1, progress))
        if !message.isEmpty { latestMessage = message }
        if let task = continuedTask { report(to: task) }
    }

    /// 書き出しが終わった（成功・失敗・中止のどれでも）
    func end(success: Bool) {
        finishedResult = success
        onExpired = nil
        continuedTask?.setTaskCompleted(success: success)
        continuedTask = nil
        fallback.end()
    }

    private func expire() {
        let handler = onExpired
        onExpired = nil
        handler?()
    }

    /// 申し込んだ作業が始まった
    private func attach(_ task: ContinuedProcessingTaskHandle, generation: Int) {
        // 前の回の作業が遅れて始まったら、すぐに終える（今の回とは関係が無い）
        guard generation == self.generation else {
            task.setTaskCompleted(success: false)
            return
        }
        // 始まる前に書き出しが終わっていたら、その結果ですぐに終える
        if let result = finishedResult {
            task.setTaskCompleted(success: result)
            return
        }
        continuedTask = task
        task.expirationHandler = { [weak self, weak task] in
            // 打ち切られたら、その場で終わったことを伝える（遅れるとアプリごと止められうる）。
            // 書き出しは止めるよう頼むだけで、後始末は次の起動時の掃除でも消える
            task?.setTaskCompleted(success: false)
            Task { @MainActor [weak self] in
                // 終わりはもう伝えたので、このあとの end で二重に伝えないよう手放す
                if let self, let task, self.continuedTask === task { self.continuedTask = nil }
                self?.expire()
            }
        }
        task.progress.totalUnitCount = Self.progressUnits
        report(to: task)
    }

    private func report(to task: ContinuedProcessingTaskHandle) {
        task.progress.completedUnitCount = Int64(latestProgress * Double(Self.progressUnits))
        if !latestMessage.isEmpty {
            task.updateTitle(task.title, subtitle: latestMessage)
        }
    }
}

// MARK: - システムの部分（テストでは偽物に差し替える）

/// 始まった作業（本物は BGContinuedProcessingTask）
protocol ContinuedProcessingTaskHandle: AnyObject {
    var title: String { get }
    var progress: Progress { get }
    var expirationHandler: (() -> Void)? { get set }
    func updateTitle(_ title: String, subtitle: String)
    func setTaskCompleted(success: Bool)
}

@available(iOS 26.0, *)
extension BGContinuedProcessingTask: ContinuedProcessingTaskHandle {}

/// 作業の申し込み（本物は BGTaskScheduler）
protocol ContinuedProcessingScheduling {
    /// 申し込む。受け付けられたらtrue。作業が始まったら`onStart`が呼ばれる（どのスレッドかは決まっていない）
    func submit(title: String, subtitle: String, onStart: @escaping (ContinuedProcessingTaskHandle) -> Void) -> Bool
}

/// 延長（本物は beginBackgroundTask をまとめた BackgroundTaskGuard）
protocol BackgroundExtending {
    func begin(name: String, onExpired: @escaping () -> Void)
    func end()
}

extension BackgroundTaskGuard: BackgroundExtending {}

/// 本物の申し込み。iOS 26 より前は申し込めないので、いつも断る
struct SystemContinuedProcessingScheduler: ContinuedProcessingScheduling {
    func submit(title: String, subtitle: String, onStart: @escaping (ContinuedProcessingTaskHandle) -> Void) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        // 名前は書き出しのたびに変える。同じ名前で2回受け付けを登録するとシステムにアプリを終了させられるため。
        // 頭の部分（<バンドルID>.export.）は MyVlogApp-Info.plist の BGTaskSchedulerPermittedIdentifiers に書いてある
        let identifier = "\(Bundle.main.bundleIdentifier ?? "app").export.\(UUID().uuidString)"
        // 始まった知らせはメインのキューで受ける。この型は画面と同じ（MainActor）に属するので、
        // 知らせを受ける処理もそこで動く前提になる。キューを指定しないと別のスレッドで呼ばれ、ずれる
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            onStart(task)
        }
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        // すぐ始められないなら断ってもらう（待たされる間に書き出しが終わるより、延長で動くほうがよい）
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }
}
