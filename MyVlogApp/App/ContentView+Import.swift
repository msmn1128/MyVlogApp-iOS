import SwiftUI
import PhotosUI
import AVFoundation
import Photos
import UIKit

// Transferable wrapper — used when PhotosPickerItem.itemIdentifier is nil
// (limited library access). Copies the received temp file to avoid it being
// cleaned up before we can read it.
private struct VideoTransfer: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { _ in
            fatalError("export not needed")
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_" + received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoTransfer(url: dest)
        }
    }
}

/// 読み込みの結果。元の並び順へ戻すためのindexと、読めたクリップ
private typealias ImportedClips = [(index: Int, clip: VlogClip)]

// MARK: - Import handlers（写真ピッカー・ファイルピッカーからのクリップ読み込み）

extension ContentView {
    func handlePhotosPick(_ items: [PhotosPickerItem]) async {
        await importClips(items) { item, fallbackDate in
            if let id = item.itemIdentifier,
               let clip = await self.makeClipFromPH(identifier: id, fallbackDate: fallbackDate) {
                return clip
            }
            if let transfer = try? await item.loadTransferable(type: VideoTransfer.self),
               let clip = await self.makeClipFromURL(
                   transfer.url, isTemporaryFile: true, fallbackDate: fallbackDate
               ) {
                return clip
            }
            return nil
        }
        photoItems = []
    }

    private func makeClipFromPH(identifier: String, fallbackDate: Date) async -> VlogClip? {
        guard let meta = VideoMetadataReader.readPhotoLibraryAsset(
            identifier: identifier, fallbackDate: fallbackDate
        ) else { return nil }

        return VlogClip.imported(
            assetIdentifier: identifier,
            timeText: meta.timeText, dateText: meta.dateText,
            durationMs: meta.durationMs,
            width: meta.width, height: meta.height,
            shotAt: Date(timeIntervalSince1970: Double(meta.shotAtMillis) / 1000),
            shotAtReliable: meta.shotAtReliable
        )
    }

    func handleFilePick(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        await importClips(urls) { url, fallbackDate in
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            return await self.makeClipFromURL(url, isTemporaryFile: false, fallbackDate: fallbackDate)
        }
    }

    /// 写真ピッカー・ファイルピッカー共通のインポート処理（Android: VlogViewModel.addClipsNow相当）。
    /// 各ソース要素→VlogClipへの変換だけを呼び出し側から渡してもらい、進捗表示・並列読み込み・
    /// 元の並び順への復元・追加・スキップ件数メッセージ・インポート中オーバーレイの
    /// 開始/終了は共通ロジックとしてここでまとめて行う。
    ///
    /// ExportManagerの書き出し処理と同様、アプリがバックグラウンドへ回ってもOSが与える
    /// 延長時間（beginBackgroundTask）で処理を継続させ、時間切れになったら明示的に
    /// キャンセルする。以前はこれが無く、バックグラウンド遷移後30秒程度でTaskが
    /// 強制サスペンドされ、復帰してもオーバーレイが消えないまま固まることがあった。
    private func importClips<Source>(
        _ sources: [Source], makeClip: @escaping (Source, Date) async -> VlogClip?
    ) async {
        guard !sources.isEmpty else { return }
        store.isImporting = true
        importProgress = 0.0
        let total = sources.count
        importMessage = "動画を読み込み中 (0/\(total))..."

        // importTaskは「先にvarで宣言してクロージャに直接キャプチャさせる」形にしてある。
        // letで一括代入する形にすると、期限切れハンドラ（backgroundTask.beginの呼び出し
        // 時点ではまだimportTaskが存在しない）から参照できず、間に参照型の箱を挟む
        // 回り道が必要になってしまう。
        var importTask: Task<ImportedClips, Never>?
        let backgroundTask = BackgroundTaskGuard()
        backgroundTask.begin(name: "VlogImport") {
            importTask?.cancel()
            backgroundTask.end()
        }

        // メタデータが一切取れない動画のためのフォールバック時刻は、並列読み込みの完了順
        // （実行順とは無関係）に左右されないよう、ここで選択順に沿って1件ずつ確実にずらした
        // 時刻を用意しておく。以前は各タスクがその場でDate()を取っており、同時に追加した
        // 動画の撮影時刻が完了順で決まってしまっていた（Android: fallbackBaseMillis + offset）。
        let fallbackBase = Date()

        let task = Task<ImportedClips, Never> {
            await loadInParallel(sources, fallbackBase: fallbackBase) { finished in
                importProgress = Double(finished) / Double(total)
                importMessage  = "動画を読み込み中 (\(finished)/\(total))..."
            } makeClip: { source, fallbackDate in
                await makeClip(source, fallbackDate)
            }
        }
        importTask = task

        var loadedClips = await task.value
        let wasCancelled = task.isCancelled
        backgroundTask.end()

        loadedClips.sort { $0.index < $1.index }
        let newClips = loadedClips.map { $0.clip }
        // 件数は引き算で辻褄を合わせず、理由ごとに数える（Android: addSkipMessage）
        let unreadable = sources.count - newClips.count
        let result = newClips.isEmpty ? VlogStore.AddResult() : store.addClips(newClips)
        // 重複・上限で入らなかったクリップは、ここまでにDocumentsへコピー済みなので実体を消す。
        // 残すと、タイムラインにも一時保存にも現れない動画がストレージを占め続ける
        discardCopies(of: result.rejected)

        store.isImporting = false
        if wasCancelled {
            store.showMessage("バックグラウンドで時間切れのため読み込みを中断しました")
        } else if let message = Formatters.addSkipMessage(
            alreadyAdded: result.alreadyPresent, unreadable: unreadable, overLimit: result.overLimit
        ) {
            store.showMessage(message)
        }
    }

    /// タイムラインへ入らなかったクリップの、Documents内のコピーを消す。
    /// フォトライブラリ由来（relativeFilePathを持たない）のクリップは実体をコピーしていないので対象外。
    private func discardCopies(of rejected: [VlogClip]) {
        for clip in rejected where clip.relativeFilePath != nil {
            guard let url = clip.resolvedFileURL else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 同時に走らせる本数を`VlogLayout.metadataParallelism`に絞って読み込む
    /// （Android: Parallel.kt mapParallel / METADATA_PARALLELISM）。
    ///
    /// 絞らないと、選んだ本数ぶんのタスクが同時にファイルコピーとデコードを始め、
    /// 大量選択時にディスクI/Oとcooperative thread poolを食い合って全体が遅くなる。
    private func loadInParallel<Source>(
        _ sources: [Source],
        fallbackBase: Date,
        onProgress: @escaping @MainActor (Int) -> Void,
        makeClip: @escaping (Source, Date) async -> VlogClip?
    ) async -> ImportedClips {
        var pending = Array(sources.enumerated()).makeIterator()
        var loaded: ImportedClips = []
        var finished = 0

        await withTaskGroup(of: (Int, VlogClip?).self) { group in
            func addNext() -> Bool {
                guard let (index, source) = pending.next() else { return false }
                // 1msずつずらすのは、フォールバックに落ちた動画どうしが同じ時刻にならないようにするため
                let fallbackDate = fallbackBase.addingTimeInterval(Double(index) / 1000)
                group.addTask {
                    guard !Task.isCancelled else { return (index, nil) }
                    return (index, await makeClip(source, fallbackDate))
                }
                return true
            }

            for _ in 0..<VlogLayout.metadataParallelism where addNext() {}

            while let (index, clip) = await group.next() {
                finished += 1
                let done = finished
                await MainActor.run { onProgress(done) }
                if let clip { loaded.append((index, clip)) }
                _ = addNext()
            }
        }
        return loaded
    }

    private func makeClipFromURL(
        _ url: URL, isTemporaryFile: Bool, fallbackDate: Date
    ) async -> VlogClip? {
        let originalFileName = url.lastPathComponent
        let fileName = UUID().uuidString + "_" + originalFileName
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dest = docDir.appendingPathComponent(fileName)

        // メタデータの読み込みは先にコピーを済ませてローカルの`dest`に対して行う。
        // ファイルピッカー経由のURLはiCloud Drive/サードパーティ製プロバイダに
        // 裏付けられていることがあり、コピー前のURLへAVURLAssetで直接
        // duration/tracks/metadataをそれぞれ読みに行くと、プロバイダ越しの
        // ランダムアクセス読み込みが何度も発生して非常に遅くなることがあった
        // （Photosピッカー側のitemIdentifier不足による低速化とは別の原因）。
        // 一度のシーケンシャルなコピーでローカルへ落としてしまえば、以降の読み込みは
        // 常にローカルファイルへの高速アクセスになる。
        //
        // このコピー自体はFileManagerの同期APIなので、Swift Concurrencyの
        // cooperative thread pool上でそのまま呼ぶとディスクI/Oの間そのスレッドを
        // 占有してしまう。GCDの別スレッドへ逃がしてpoolを塞がないようにする。
        do {
            try await copyOrMoveOffCooperativePool(at: url, to: dest, move: isTemporaryFile)
        } catch {
            return nil
        }

        // 撮影時刻をファイル名から拾う手がかりは、コピー先（UUIDが前置される）ではなく
        // 元のファイル名にしかないので別途渡す
        guard let meta = await VideoMetadataReader.readFile(
            at: dest, originalFileName: originalFileName, fallbackDate: fallbackDate
        ) else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }

        return VlogClip.imported(
            fileURL: dest, relativeFilePath: fileName,
            timeText: meta.timeText, dateText: meta.dateText,
            durationMs: meta.durationMs,
            width: meta.width, height: meta.height,
            shotAt: Date(timeIntervalSince1970: Double(meta.shotAtMillis) / 1000),
            shotAtReliable: meta.shotAtReliable,
            // 同じ動画を2回選んだときに重複と分かるよう、中身の指紋を持たせる。
            // コピー先（dest）から取るのは、ここが取り込み後に残る実体だから
            // （元のURLはピッカーが貸してくれた一時的なものかもしれない）
            contentKey: FileContentKey.make(for: dest)
        )
    }

    /// FileManagerの同期コピー/移動をGCDのグローバルキューへ逃がし、呼び出し側の
    /// cooperative thread poolのスレッドをディスクI/Oで塞がないようにする
    private func copyOrMoveOffCooperativePool(at src: URL, to dest: URL, move: Bool) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    if move {
                        try FileManager.default.moveItem(at: src, to: dest)
                    } else {
                        try FileManager.default.copyItem(at: src, to: dest)
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
