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

private typealias ImportedClips = [(index: Int, clip: VlogClip)]

// MARK: - Import handlers（写真ピッカー・ファイルピッカーからのクリップ読み込み）

extension ContentView {
    func handlePhotosPick(_ items: [PhotosPickerItem]) async {
        await importClips(items) { item in
            if let id = item.itemIdentifier, let clip = await self.makeClipFromPH(identifier: id) {
                return clip
            } else if let transfer = try? await item.loadTransferable(type: VideoTransfer.self),
                      let clip = await self.makeClipFromURL(transfer.url, isTemporaryFile: true) {
                return clip
            }
            return nil
        }
        photoItems = []
    }

    private func makeClipFromPH(identifier: String) async -> VlogClip? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject else { return nil }
        guard asset.duration > 0 && asset.duration.isFinite else { return nil }
        let durationMs = Int64(asset.duration * 1000)
        guard durationMs > 0 else { return nil }

        let creationDate = asset.creationDate ?? Date()
        let (time, date) = Formatters.clipTimeAndDate(creationDate)

        return VlogClip.imported(
            assetIdentifier: identifier,
            timeText: time, dateText: date,
            durationMs: durationMs,
            width: asset.pixelWidth, height: asset.pixelHeight,
            shotAt: creationDate
        )
    }

    func handleFilePick(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        await importClips(urls) { url in
            _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            return await self.makeClipFromURL(url, isTemporaryFile: false)
        }
    }

    /// 写真ピッカー・ファイルピッカー共通のインポート処理（Android: 追加時の動画一括読み込み相当）。
    /// 各ソース要素→VlogClipへの変換だけを呼び出し側から渡してもらい、進捗表示・並列読み込み・
    /// 元の並び順への復元・追加・スキップ件数メッセージ・インポート中オーバーレイの
    /// 開始/終了は共通ロジックとしてここでまとめて行う。
    ///
    /// ExportManagerの書き出し処理と同様、アプリがバックグラウンドへ回ってもOSが与える
    /// 延長時間（beginBackgroundTask）で処理を継続させ、時間切れになったら明示的に
    /// キャンセルする。以前はこれが無く、バックグラウンド遷移後30秒程度でTaskが
    /// 強制サスペンドされ、復帰してもisImportingオーバーレイが消えないまま
    /// 固まることがあった。
    private func importClips<Source>(
        _ sources: [Source], makeClip: @escaping (Source) async -> VlogClip?
    ) async {
        guard !sources.isEmpty else { return }
        isImporting = true
        importProgress = 0.0
        let total = sources.count
        importMessage = "動画を読み込み中 (0/\(total))..."

        // importTaskはbackgroundTaskIDと同じく「先にvarで宣言してクロージャに直接
        // キャプチャさせる」形にしてある。letで一括代入する形にすると、期限切れ
        // ハンドラ（beginBackgroundTaskの呼び出し時点ではまだimportTaskが存在しない）
        // から参照できず、間に参照型の箱を挟む回り道が必要になってしまう。
        var importTask: Task<ImportedClips, Never>?
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        func endBackgroundTaskIfNeeded() {
            guard backgroundTaskID != .invalid else { return }
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VlogImport") {
            importTask?.cancel()
            endBackgroundTaskIfNeeded()
        }

        let task = Task<ImportedClips, Never> {
            var loadedClips: ImportedClips = []
            await withTaskGroup(of: (Int, VlogClip?).self) { group in
                for (index, source) in sources.enumerated() {
                    group.addTask {
                        guard !Task.isCancelled else { return (index, nil) }
                        return (index, await makeClip(source))
                    }
                }

                var finishedCount = 0
                for await (idx, clip) in group {
                    finishedCount += 1
                    await MainActor.run {
                        importProgress = Double(finishedCount) / Double(total)
                        importMessage = "動画を読み込み中 (\(finishedCount)/\(total))..."
                    }
                    if let clip {
                        loadedClips.append((idx, clip))
                    }
                }
            }
            return loadedClips
        }
        importTask = task

        var loadedClips = await task.value
        let wasCancelled = task.isCancelled
        endBackgroundTaskIfNeeded()

        loadedClips.sort { $0.index < $1.index }
        let newClips = loadedClips.map { $0.clip }

        if !newClips.isEmpty { store.addClips(newClips) }
        let skipped = sources.count - newClips.count
        if wasCancelled {
            store.showMessage("バックグラウンドで時間切れのため読み込みを中断しました")
        } else if skipped > 0 {
            store.showMessage("\(skipped) 件の動画は長さを取得できませんでした")
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        isImporting = false
    }

    private func makeClipFromURL(_ url: URL, isTemporaryFile: Bool = false) async -> VlogClip? {
        let fileName = UUID().uuidString + "_" + url.lastPathComponent
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
        // 占有してしまう（importClipsは動画ごとに並列でこの関数を呼ぶため、
        // 選択枚数が多いとpoolの限られたスレッドを食い合って他の非同期処理まで
        // 詰まりやすい）。GCDの別スレッドへ逃がしてpoolを塞がないようにする。
        do {
            try await copyOrMoveOffCooperativePool(at: url, to: dest, move: isTemporaryFile)
        } catch {
            return nil
        }

        let av = AVURLAsset(url: dest)
        async let durTask = av.load(.duration)
        async let tracksTask = av.load(.tracks)
        async let metaTask = av.load(.metadata)

        guard let dur = try? await durTask, dur.seconds > 0, dur.seconds.isFinite else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        let durationMs = Int64(dur.seconds * 1000)

        // Get display size (applying rotation transform)
        var w = 1920, h = 1080
        if let tracks = try? await tracksTask,
           let vTrack = tracks.first(where: { $0.mediaType == .video }) {
            async let sizeTask = vTrack.load(.naturalSize)
            async let prefTask = vTrack.load(.preferredTransform)
            if let natSize = try? await sizeTask, let pref = try? await prefTask {
                let rect = CGRect(origin: .zero, size: natSize).applying(pref)
                w = Int(abs(rect.width).rounded())
                h = Int(abs(rect.height).rounded())
            }
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let fileDate = (attrs?[.creationDate] as? Date) ?? Date()
        let metadata = (try? await metaTask) ?? []
        let actualDate = await extractDateFromMetadata(metadata: metadata, fallbackDate: fileDate)
        let (time, dateStr) = Formatters.clipTimeAndDate(actualDate)

        return VlogClip.imported(
            fileURL: dest, relativeFilePath: fileName,
            timeText: time, dateText: dateStr,
            durationMs: durationMs,
            width: w, height: h,
            shotAt: actualDate
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

    private func extractDateFromMetadata(metadata: [AVMetadataItem], fallbackDate: Date) async -> Date {
        let creationItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierCreationDate)
        if let item = creationItems.first, let date = await dateFromMetadataItem(item) {
            return date
        }
        let qtItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
        if let item = qtItems.first, let date = await dateFromMetadataItem(item) {
            return date
        }
        return fallbackDate
    }

    /// dateValue/stringValueを1回のロード呼び出しでまとめて取得する
    /// （別々にawaitすると同じitemへの往復が2回になる）
    private func dateFromMetadataItem(_ item: AVMetadataItem) async -> Date? {
        guard let (dateVal, strVal) = try? await item.load(.dateValue, .stringValue) else { return nil }
        if let dateVal { return dateVal }
        if let strVal, let parsed = parseDateString(strVal) { return parsed }
        return nil
    }

    private func parseDateString(_ str: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) { return d }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy:MM:dd HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for f in formats {
            df.dateFormat = f
            if let d = df.date(from: str) { return d }
        }
        return nil
    }
}
