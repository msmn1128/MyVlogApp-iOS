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
@MainActor
final class ExportKeepAlive {
    private let fallback = BackgroundTaskGuard()
    private var onExpired: (() -> Void)?

    /// いま申し込んでいる作業（iOS 26以降だけ。型はBGContinuedProcessingTask）。
    /// 申し込んでから実際に始まるまでの間はnil
    private var continuedTask: AnyObject?
    /// 作業が始まる前に書き出しが終わっていたら、始まった時点ですぐに終える
    private var finishedResult: Bool?
    private var latestProgress: Double = 0
    private var latestMessage: String = ""

    /// 進み具合をこの細かさで報告する（0.1%刻み）
    private static let progressUnits: Int64 = 1_000

    /// - Parameters:
    ///   - title: システムの表示に出す題（例「VLOGを書き出し中」）
    ///   - onExpired: 続けられなくなったとき（システムの表示から中止された・時間切れ）に呼ぶ。書き出しを止めること
    func begin(title: String, onExpired: @escaping () -> Void) {
        self.onExpired = onExpired
        finishedResult = nil
        continuedTask = nil
        latestProgress = 0
        latestMessage = ""
        if #available(iOS 26.0, *), submitContinuedProcessing(title: title) { return }
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
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            report(to: task)
        }
    }

    /// 書き出しが終わった（成功・失敗・中止のどれでも）
    func end(success: Bool) {
        finishedResult = success
        onExpired = nil
        if #available(iOS 26.0, *), let task = continuedTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
        continuedTask = nil
        fallback.end()
    }

    private func expire() {
        let handler = onExpired
        onExpired = nil
        handler?()
    }

    // MARK: - iOS 26 以降

    /// 作業を申し込む。断られたらfalse（呼び出し側は延長へ切り替える）
    @available(iOS 26.0, *)
    private func submitContinuedProcessing(title: String) -> Bool {
        // 名前は書き出しのたびに変える。同じ名前で2回受け付けの登録をするとシステムにアプリを終了させられるため。
        // 頭の部分（<バンドルID>.export.）は Info.plist の BGTaskSchedulerPermittedIdentifiers に書いてある
        let identifier = "\(Bundle.main.bundleIdentifier ?? "app").export.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.attach(task)
            }
        }
        guard registered else { return false }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "準備中...")
        // すぐ始められないなら断ってもらう（待たされる間に書き出しが終わるより、延長で動くほうがよい）
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    /// 申し込んだ作業が始まった
    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        // 始まる前に書き出しが終わっていたら、すぐに終える
        if let result = finishedResult {
            task.setTaskCompleted(success: result)
            return
        }
        continuedTask = task
        task.expirationHandler = { [weak self] in
            // 打ち切られたら、その場で終わったことを伝える（遅れるとアプリごと止められうる）。
            // 書き出しは止めるよう頼むだけで、後始末は次の起動時の掃除でも消える
            task.setTaskCompleted(success: false)
            Task { @MainActor [weak self] in
                self?.continuedTask = nil
                self?.expire()
            }
        }
        task.progress.totalUnitCount = Self.progressUnits
        report(to: task)
    }

    @available(iOS 26.0, *)
    private func report(to task: BGContinuedProcessingTask) {
        task.progress.completedUnitCount = Int64(latestProgress * Double(Self.progressUnits))
        if !latestMessage.isEmpty {
            task.updateTitle(task.title, subtitle: latestMessage)
        }
    }
}
