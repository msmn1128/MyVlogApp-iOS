import AVFoundation
import Combine
import UIKit
import Photos
@preconcurrency import UserNotifications

// MARK: - ExportManager

/// Observationを使う理由は VideoPlayerManager のコメントを参照
@MainActor
@Observable
final class ExportManager {
    var isExporting: Bool   = false
    // 進み具合と工程は、アプリを離れて書き出しているときのシステムの表示にも伝える（ExportKeepAlive）
    var progress:    Double = 0 { didSet { keepAlive.update(progress: progress, message: message) } }
    var message:     String = "" { didSet { keepAlive.update(progress: progress, message: message) } }
    /// 完了・中止・失敗を伝える一過性の通知（Android: VlogEvent.MessageのToast相当）。
    /// isExportingがfalseになってオーバーレイが消えた後も独立して表示され続ける。
    var toastMessage: String? = nil
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    @ObservationIgnored private var exportTask: Task<Void, Never>?
    /// アプリがバックグラウンドへ回っても書き出しを続けるための延命申請
    /// （Android: VlogExportServiceのフォアグラウンドサービス化に相当）
    ///
    /// iOS 26以降はシステムの「続ける作業」として申し込み、アプリを離れても最後まで書き出す。
    /// それより前の端末では延長（約30秒）で動く（ExportKeepAlive）
    @ObservationIgnored private let keepAlive = ExportKeepAlive()
    /// AVFoundationの読み書き・CGContextへの焼き込みなど重い処理だけを担当するactor。
    /// メインスレッドを塞がないよう、ExportManager（@MainActor）から切り離してある
    /// （詳しい経緯はExportWorker.swiftのコメントを参照）
    private let worker = ExportWorker()

    init() {
        // 前回、書き出し中に強制終了していた場合の後始末。結合途中の動画は数GBになりうる。
        //
        // 消すのは、この起動より前に作られたファイルだけ。掃除は後回しの優先度で走るので、実際に
        // 走る頃には書き出しが始まっていることがある。以前は起動時刻を見ていなかったため、
        // 始まったばかりの書き出しの作業ファイルまで消し、書き出しが「長さを読めない
        // （-11800 / -17913）」で失敗していた（テストではアプリ起動の直後に書き出すので、
        // ビルド直後の1回目にまれに起きていた。Android 7c30371 と同じ種類の問題）
        let launchedAt = Date()
        Task.detached(priority: .background) {
            ExportWorker.cleanupOrphanedWorkFiles(createdBefore: launchedAt)
        }
    }

    /// @param customTitleText タイトルカードに焼き込む文言。nil/空文字なら先頭クリップの
    ///   撮影日（VlogClip.dateText）を使う。タイトル作成ダイアログで自由入力を選んだときのみ渡る
    ///   （Android: VlogViewModel.export の customTitleText と同じ役割）。
    /// 書き出しが始まらない場合は、黙って戻らず理由をトーストで返す
    /// （何も起きないと「押せていない」のか「始まっているのか」が画面から分からないため。
    /// Android: VlogViewModel.export の3つの early return と同じ）。
    func startExport(
        clips: [VlogClip], timelineMuted: Bool = false, includeTitle: Bool = true, customTitleText: String? = nil
    ) {
        // isExportingだけでなくexportTaskの生存も見る。「中止」を押した直後は
        // isExportingが下りていても、実処理（AVAssetExportSessionや写真への保存）は
        // 次のキャンセル判定地点まで走り続けるため、ここを素通りすると2本目が並行して始まる
        if isExporting || exportTask != nil {
            showMessage("すでに書き出し中です")
            return
        }
        if clips.isEmpty {
            showMessage("動画を追加してください")
            return
        }
        if clips.contains(where: { !$0.isValid }) {
            showMessage("トリミング範囲が不正なクリップがあります")
            return
        }
        // 追加時に上限を守っているが、上限を設ける前の保存データを復元した場合などに超えうる
        // （Android: VlogExporter.export の同じチェック）
        if clips.count > VlogLayout.maxClips {
            showMessage("クリップが多すぎます（上限\(VlogLayout.maxClips)本、現在\(clips.count)本）。クリップを減らしてください")
            return
        }
        // 開けない動画が混ざっていると、途中でAVFoundationの「動画が見つかりません: <識別子>」のような
        // どれが原因か分からないエラーで失敗していた。何本目のどの動画かを伝えて、始める前に断る
        let missing = ClipAvailability.unavailableIndices(in: clips)
        if !missing.isEmpty {
            showMessage(Formatters.missingClipsMessage(indices: missing, clips: clips))
            return
        }
        // 空き容量が足りないと、途中で英語のエラーのまま失敗していた（ExportSpace）
        let required = ExportSpace.requiredFreeBytes(
            durationMs: ExportSpace.exportDurationMs(clips: clips, includeTitle: includeTitle)
        )
        if let available = ExportSpace.availableBytes(), available < required {
            showMessage(ExportSpace.notEnoughSpaceMessage(required: required, available: available))
            return
        }

        // 完了通知の許可はここで求める。完了時に求めると、書き出しが終わった瞬間に
        // 許可ダイアログが割り込む（すでに可否が決まっていれば即座に返るので通常は何も出ない）
        requestNotificationAuthorizationIfNeeded()

        isExporting = true
        progress    = 0
        message     = includeTitle ? "タイトルを作成中..." : "クリップを処理中..."
        keepAlive.begin(title: "VLOGを書き出し中") { [weak self] in
            // 続けられなくなった（システムの表示から中止された・延長を使い切った）＝ここで畳むしかない。
            // 書き出しを止めれば、後始末（作業ファイルの削除）を終えたところで runExport が延長を返す
            self?.exportTask?.cancel()
        }
        // 書き出しは「進捗を見せながら裏で進む長い処理」なので、画面の操作と同じ優先度では走らせない。
        // MainActorから素のTaskで起こすとuser-initiated相当になり、AVFoundationの内部スレッド
        // （utility）をそれより高い優先度で待つ形＝優先度逆転になる（ExportWorkerのqueueと揃える）。
        // 進捗バーが出ていてUIは触れるままなので、utilityがこの仕事の本来の優先度。
        exportTask  = Task(priority: .utility) {
            await runExport(
                clips: clips, timelineMuted: timelineMuted, includeTitle: includeTitle, customTitleText: customTitleText
            )
        }
    }

    /// 中止を要求する。ここでは`isExporting`を下ろさない。
    ///
    /// キャンセルは`Task.checkCancellation()`の地点まで届かず、実処理はしばらく走り続ける。
    /// ここで下ろしてしまうと、その間に「書き出し」を押せてしまい2本目が並行して始まる。
    /// 実際に終わったことを知っている`runExport`の後始末だけが状態を戻す。
    ///
    /// 延長（ExportKeepAlive）もここでは返さない。止まるまでと後始末の間にアプリを止められないよう、
    /// runExport が終わったところで返す。
    func cancel() {
        exportTask?.cancel()
    }

    /// 完了・中止・失敗を画面上部/下部のトーストで一時的に知らせる（Android: ToastによるVlogEvent.Message相当）
    private func showMessage(_ text: String) {
        toastTask?.cancel()
        toastMessage = text
        toastTask = ToastTimer.scheduleClear(after: ToastTimer.duration(for: text)) { [weak self] in self?.toastMessage = nil }
    }

    /// 完了通知の許可を求める。書き出しを始めるときに呼ぶ（startExport）。
    ///
    /// 以前は`notifyCompletion`の中、つまり書き出しが終わった瞬間に求めていたため、
    /// 初回は完了と同時に許可ダイアログが割り込んでいた。可否が決まったあとは
    /// このAPIは何も出さずに即座に返るので、毎回呼んで構わない。
    private func requestNotificationAuthorizationIfNeeded() {
        #if DEBUG
        // UIテスト中は、許可ダイアログがXCUITestの操作を遮ってテストを不安定にするので求めない
        // （UITestSupport.swift。リリースビルドにこの分岐は入らない）
        guard !UITestSupport.isRunningUITests else { return }
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 書き出しの結果をローカル通知で知らせる（Android: 完了時のToast「ギャラリーに保存しました」相当。
    /// バックグラウンドで書き出しが終わった場合に特に役立つ）。
    /// 許可されていなければ`add`が黙って何もしないので、ここでは可否を見ない
    private func notifyCompletion(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Main pipeline

    private func runExport(clips: [VlogClip], timelineMuted: Bool, includeTitle: Bool, customTitleText: String?) async {
        var tempFiles: [URL] = []
        // タイトルカードに焼き込む文言。ファイル名には使わない（書き出した日付から作る）
        let titleText = Self.resolveTitleText(customTitleText: customTitleText, firstClipDateText: clips.first?.dateText ?? "")
        // 書き出した動画自体の作成日時。写真アプリの並び順と日付表示に使われる
        // （Android: VlogExporter.export の createdAtMillis）
        let createdAt = Date()
        // 最後まで書き出して写真に保存できたか（システムの表示に、成功・失敗として伝える）
        var succeeded = false
        do {
            // 写真に保存してよいかを、書き出しを始める前に確かめる（下のensurePhotoLibraryAddAccess）
            try await Self.ensurePhotoLibraryAddAccess()
            let clipURLs = try await buildClipURLs(
                clips: clips, timelineMuted: timelineMuted, includeTitle: includeTitle, titleText: titleText, tempFiles: &tempFiles
            )

            update("結合中...")
            let merged = try await worker.concatenate(urls: clipURLs)
            tempFiles.append(merged)
            // クリップごとの作業ファイルは結合したら要らない。写真への取り込み（結合した動画をもう1つ
            // 複製する）の前に消して、いちばん多く抱える瞬間を出来上がりの2倍に抑える（ExportSpace）
            for url in clipURLs { try? FileManager.default.removeItem(at: url) }
            progress = 0.9

            update("保存中...")
            let displayName = Formatters.exportFileName(exportedAt: createdAt)
            try await worker.saveToPhotoLibrary(url: merged, displayName: displayName, createdAt: createdAt)
            progress = 1.0
            update("完了")
            let savedMessage = "写真に保存しました\n\(displayName)"
            notifyCompletion(title: "書き出し完了", body: savedMessage)
            showMessage(savedMessage)
            succeeded = true
        } catch is CancellationError {
            update("")
            showMessage("書き出しを中止しました")
        } catch {
            let message = Self.failureMessage(for: error)
            update("エラー: \(message)")
            notifyCompletion(title: "書き出しに失敗しました", body: message)
            showMessage(message)
        }
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        // 書き出し用に最高画質で開いたAVAssetは、デコーダとファイルハンドルを抱えたまま
        // キャッシュに残る。プレビュー用（preview:接頭辞）は残し、こちらだけ捨てる
        await AssetLoader.shared.releaseExportAssets()
        // 実際に終わったここだけが状態を戻す（cancel()は要求するだけ。理由はcancel()のコメント）
        exportTask  = nil
        isExporting = false
        keepAlive.end(success: succeeded)
    }

    /// タイトルカード生成〜各クリップの処理までを1本にまとめたもの（runExportから抽出）。
    /// 作った一時ファイルは呼び出し元のtempFilesへ積んでいき、runExport側で
    /// 成功・失敗どちらの経路でも最後にまとめて削除する
    private func buildClipURLs(
        clips: [VlogClip], timelineMuted: Bool, includeTitle: Bool, titleText: String, tempFiles: inout [URL]
    ) async throws -> [URL] {
        var clipURLs: [URL] = []
        // 進捗の割り当て: タイトル（作る場合）に1コマ、各クリップに1コマ、最後の結合・保存に1コマ。
        // 以前はタイトルのぶんを分母に足しておきながらクリップ0本目を0から始めていたため、
        // タイトルを作っている間ずっとバーが0のまま止まって見えていた
        let titleSteps = includeTitle ? 1 : 0
        let totalSteps = Double(clips.count + titleSteps + 1)

        if includeTitle {
            update("タイトルを作成中...")
            var titleURL = try await worker.createTitleCard(titleText: titleText)
            tempFiles.append(titleURL)
            if !timelineMuted {
                let withSfx = try await worker.addTitleSfx(to: titleURL)
                tempFiles.append(withSfx)
                titleURL = withSfx
            }
            clipURLs.append(titleURL)
            progress = Double(titleSteps) / totalSteps
            guard !Task.isCancelled else { throw CancellationError() }
        }

        for (i, clip) in clips.enumerated() {
            update("クリップ \(i + 1)/\(clips.count) を処理中...")
            // クリップiは進捗全体の [(i+タイトル分)/分母, (i+1+タイトル分)/分母] を受け持つ。
            // 1本が長いとバーが止まって見えるので、クリップ内の進み具合もこの区間へ写して反映する
            let base = Double(i + titleSteps) / totalSteps
            let span = 1 / totalSteps
            let url = try await worker.processClip(
                clip, silent: clip.isSilentInExport(timelineMuted: timelineMuted)
            ) { [weak self] fraction in
                // weak selfのまま内側のTaskへ持ち込むと「varのキャプチャ」になる
                // （Swift 6モードではエラー）。先に取り出してから渡す
                guard let self else { return }
                Task { @MainActor in self.progress = base + fraction * span }
            }
            clipURLs.append(url)
            tempFiles.append(url)
            progress = Double(i + 1 + titleSteps) / totalSteps
            guard !Task.isCancelled else { throw CancellationError() }
        }
        return clipURLs
    }

    private func update(_ msg: String) {
        message = msg
    }

    /// 書き出した動画を写真へ保存してよいかを、書き出しを始める前に確かめる。まだ聞いていなければここで聞く。
    ///
    /// 以前は書き出しが全部終わってから（写真へ保存する直前に）初めて聞いていた。初めて書き出す人は
    /// 長い書き出しを待ったあとで許可を聞かれ、断るとその動画は捨てられた。書き出し中に別のアプリへ
    /// 移っていると許可の画面を出せず、許可しないのと同じ扱いで失敗していた。
    /// 許可されていなければ、始める前に理由を伝えて断る（書き出しの時間を無駄にしない）
    private static func ensurePhotoLibraryAddAccess() async throws {
        #if DEBUG
        // UIテスト中は、許可の画面がXCUITestの操作を遮るので聞かない（通知の許可と同じ扱い。
        // 保存まで通すテストは無い）
        if UITestSupport.isRunningUITests { return }
        #endif
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else { throw ExportError.photoLibraryAccessDenied }
        default:
            throw ExportError.photoLibraryAccessDenied
        }
    }

    /// 書き出しに失敗したときに見せる文言。単体テストから直接呼ぶためinternal・nonisolated。
    ///
    /// - 容量不足は、どうすればよいかまで日本語で伝える（ExportSpace）
    /// - アプリが自分で出すエラー（ExportError）は、その日本語の文言のまま
    /// - それ以外（AVFoundationなど）は、英語の文言だけが出ていて、書き出しに失敗したことすら
    ///   読み取りにくかった。「書き出しに失敗しました」と日本語で始め、元の文言は括弧に添える
    ///   （原因を追うときの手がかりとして残す）
    nonisolated static func failureMessage(for error: Error) -> String {
        if ExportSpace.isNoSpaceError(error) { return ExportSpace.ranOutOfSpaceMessage }
        if let exportError = error as? ExportError, let description = exportError.errorDescription {
            return description
        }
        return "書き出しに失敗しました（\(error.localizedDescription)）"
    }

    /// タイトルカードへ焼き込む文言を決める（Android: VlogExporter.exportの
    /// `customTitleText ?: firstDate` と同じ判定）。
    ///
    /// 自由入力は前後の空白・改行を落としてから見る。空白だけを打って確定した場合も
    /// 「入力なし」として先頭クリップの撮影日へ戻す（落とさないと、見た目は空なのに
    /// 撮影日ではなく空白がタイトルカードへ焼き込まれる）。
    ///
    /// フォールバックの判定をここ1箇所に集約してあるのは、以前はタイトル作成ダイアログ側でも
    /// 同じ判定をしていて、片方だけtrimしているというズレが生まれていたため。
    /// 呼び出し側（ダイアログ）は入力された文字列をそのまま渡してよい。
    /// 単体テストから直接呼ぶためinternal・nonisolated。
    nonisolated static func resolveTitleText(customTitleText: String?, firstClipDateText: String) -> String {
        let trimmed = customTitleText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? firstClipDateText : trimmed
    }
}

// MARK: - Errors

enum ExportError: LocalizedError {
    case noVideoTrack
    case sessionCreationFailed
    case saveToLibraryFailed
    case photoLibraryAccessDenied
    /// 書き込み側の画素バッファのプールから1枚も借りられなかった
    /// （ExportWorker.makeOutputBuffer。通常は起こらない）
    case pixelBufferPoolUnavailable

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:               return "動画トラックが見つかりません"
        case .sessionCreationFailed:      return "エクスポートセッションを作成できません"
        case .saveToLibraryFailed:        return "カメラロールへの保存に失敗しました"
        case .photoLibraryAccessDenied:   return "写真ライブラリへの保存権限がありません。設定アプリから許可してください。"
        case .pixelBufferPoolUnavailable: return "書き出し用の画像バッファを確保できません"
        }
    }
}
