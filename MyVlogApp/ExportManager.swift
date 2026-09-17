import AVFoundation
import Combine
import UIKit
import Photos
@preconcurrency import UserNotifications

// MARK: - ExportManager

@MainActor
class ExportManager: ObservableObject {
    @Published var isExporting: Bool   = false
    @Published var progress:    Double = 0
    @Published var message:     String = ""
    /// 完了・中止・失敗を伝える一過性の通知（Android: VlogEvent.MessageのToast相当）。
    /// isExportingがfalseになってオーバーレイが消えた後も独立して表示され続ける。
    @Published var toastMessage: String? = nil
    private var toastTask: Task<Void, Never>?

    private var exportTask: Task<Void, Never>?
    /// アプリがバックグラウンドへ回っても書き出しを続けるための延命申請
    /// （Android: VlogExportServiceのフォアグラウンドサービス化に相当）
    private let backgroundTask = BackgroundTaskGuard()
    /// AVFoundationの読み書き・CGContextへの焼き込みなど重い処理だけを担当するactor。
    /// メインスレッドを塞がないよう、ExportManager（@MainActor）から切り離してある
    /// （詳しい経緯はExportWorker.swiftのコメントを参照）
    private let worker = ExportWorker()

    /// @param customTitleText タイトルカードに焼き込む文言。nil/空文字なら先頭クリップの
    ///   撮影日（VlogClip.dateText）を使う。タイトル作成ダイアログで自由入力を選んだときのみ渡る
    ///   （Android: VlogViewModel.export の customTitleText と同じ役割）。
    func startExport(
        clips: [VlogClip], timelineMuted: Bool = false, includeTitle: Bool = true, customTitleText: String? = nil
    ) {
        guard !isExporting, !clips.isEmpty else { return }
        isExporting = true
        progress    = 0
        message     = includeTitle ? "タイトルを作成中..." : "クリップを処理中..."
        backgroundTask.begin(name: "VlogExport") { [weak self] in
            // OSに与えられた延長時間を使い切った＝ここで畳むしかない
            self?.exportTask?.cancel()
            self?.backgroundTask.end()
        }
        exportTask  = Task {
            await runExport(
                clips: clips, timelineMuted: timelineMuted, includeTitle: includeTitle, customTitleText: customTitleText
            )
        }
    }

    func cancel() {
        exportTask?.cancel()
        isExporting = false
        backgroundTask.end()
    }

    /// 完了・中止・失敗を画面上部/下部のトーストで一時的に知らせる（Android: ToastによるVlogEvent.Message相当）
    private func showMessage(_ text: String) {
        toastTask?.cancel()
        toastMessage = text
        toastTask = ToastTimer.scheduleClear { [weak self] in self?.toastMessage = nil }
    }

    /// 書き出し完了をローカル通知で知らせる（Android: 完了時のToast「ギャラリーに保存しました」相当。
    /// バックグラウンドで書き出しが終わった場合に特に役立つ）
    private func notifyCompletion(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body  = body
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request)
        }
    }

    // MARK: - Main pipeline

    private func runExport(clips: [VlogClip], timelineMuted: Bool, includeTitle: Bool, customTitleText: String?) async {
        var tempFiles: [URL] = []
        // includeTitleの真偽に関わらず、ファイル名は常にこの文言を基準にする
        // （Android: VlogExporter.exportのtitleTextと同じ方針）
        let titleText = Self.resolveTitleText(customTitleText: customTitleText, firstClipDateText: clips.first?.dateText ?? "")
        do {
            let clipURLs = try await buildClipURLs(
                clips: clips, timelineMuted: timelineMuted, includeTitle: includeTitle, titleText: titleText, tempFiles: &tempFiles
            )

            update("結合中...")
            let merged = try await worker.concatenate(urls: clipURLs)
            tempFiles.append(merged)
            progress = 0.9

            update("保存中...")
            let displayName = await worker.displayName(titleText: titleText)
            try await worker.saveToPhotoLibrary(url: merged, displayName: displayName)
            progress = 1.0
            update("完了")
            let savedMessage = "写真に保存しました\n\(displayName)"
            notifyCompletion(title: "書き出し完了", body: savedMessage)
            showMessage(savedMessage)
        } catch is CancellationError {
            update("")
            showMessage("書き出しを中止しました")
        } catch {
            update("エラー: \(error.localizedDescription)")
            notifyCompletion(title: "書き出しに失敗しました", body: error.localizedDescription)
            showMessage(error.localizedDescription)
        }
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        isExporting = false
        backgroundTask.end()
    }

    /// タイトルカード生成〜各クリップの処理までを1本にまとめたもの（runExportから抽出）。
    /// 作った一時ファイルは呼び出し元のtempFilesへ積んでいき、runExport側で
    /// 成功・失敗どちらの経路でも最後にまとめて削除する
    private func buildClipURLs(
        clips: [VlogClip], timelineMuted: Bool, includeTitle: Bool, titleText: String, tempFiles: inout [URL]
    ) async throws -> [URL] {
        var clipURLs: [URL] = []
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
            guard !Task.isCancelled else { throw CancellationError() }
        }

        let progressDenominator = Double(clips.count + (includeTitle ? 2 : 1))
        for (i, clip) in clips.enumerated() {
            update("クリップ \(i + 1)/\(clips.count) を処理中...")
            let url = try await worker.processClip(clip, silent: clip.isSilentInExport(timelineMuted: timelineMuted))
            clipURLs.append(url)
            tempFiles.append(url)
            progress = Double(i + 1) / progressDenominator
            guard !Task.isCancelled else { throw CancellationError() }
        }
        return clipURLs
    }

    private func update(_ msg: String) {
        message = msg
    }

    /// customTitleTextが空/未指定なら先頭クリップの撮影日にフォールバックする
    /// （Android: VlogExporter.exportの `customTitleText ?: firstDate` と同じ判定）。
    private static func resolveTitleText(customTitleText: String?, firstClipDateText: String) -> String {
        if let custom = customTitleText, !custom.isEmpty { return custom }
        return firstClipDateText
    }
}

// MARK: - Errors

enum ExportError: LocalizedError {
    case noVideoTrack
    case sessionCreationFailed
    case saveToLibraryFailed
    case photoLibraryAccessDenied

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:              return "動画トラックが見つかりません"
        case .sessionCreationFailed:     return "エクスポートセッションを作成できません"
        case .saveToLibraryFailed:       return "カメラロールへの保存に失敗しました"
        case .photoLibraryAccessDenied:  return "写真ライブラリへの保存権限がありません。設定アプリから許可してください。"
        }
    }
}
