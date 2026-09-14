import SwiftUI
import PhotosUI
import AVFoundation
import Photos

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
        let (time, date) = formatDate(creationDate)

        return VlogClip(
            id:               UUID(),
            assetIdentifier:  identifier,
            fileURL:          nil,
            relativeFilePath: nil,
            timeText:         time,
            dateText:         date,
            durationMs:       durationMs,
            width:            max(1, asset.pixelWidth),
            height:           max(1, asset.pixelHeight),
            texts:            [TextSegment()],
            startMs:          0,
            endMs:            durationMs,
            shotAtMillis:     Int64(creationDate.timeIntervalSince1970 * 1000)
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
    private func importClips<Source>(
        _ sources: [Source], makeClip: @escaping (Source) async -> VlogClip?
    ) async {
        guard !sources.isEmpty else { return }
        isImporting = true
        importProgress = 0.0
        let total = sources.count
        importMessage = "動画を読み込み中 (0/\(total))..."

        var loadedClips: [(index: Int, clip: VlogClip)] = []

        await withTaskGroup(of: (Int, VlogClip?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    (index, await makeClip(source))
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

        loadedClips.sort { $0.index < $1.index }
        let newClips = loadedClips.map { $0.clip }

        if !newClips.isEmpty { store.addClips(newClips) }
        let skipped = sources.count - newClips.count
        if skipped > 0 {
            store.showMessage("\(skipped) 件の動画は長さを取得できませんでした")
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        isImporting = false
    }

    private func makeClipFromURL(_ url: URL, isTemporaryFile: Bool = false) async -> VlogClip? {
        let av = AVURLAsset(url: url)

        async let durTask = av.load(.duration)
        async let tracksTask = av.load(.tracks)
        async let metaTask = av.load(.metadata)

        guard let dur = try? await durTask, dur.seconds > 0, dur.seconds.isFinite else { return nil }
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

        let fileName = UUID().uuidString + "_" + url.lastPathComponent
        guard let docDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let dest = docDir.appendingPathComponent(fileName)

        if isTemporaryFile {
            try? FileManager.default.moveItem(at: url, to: dest)
        } else {
            try? FileManager.default.copyItem(at: url, to: dest)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let fileDate = (attrs?[.creationDate] as? Date) ?? Date()
        let metadata = (try? await metaTask) ?? []
        let actualDate = extractDateFromMetadata(metadata: metadata, fallbackDate: fileDate)
        let (time, dateStr) = formatDate(actualDate)

        return VlogClip(
            id:               UUID(),
            assetIdentifier:  nil,
            fileURL:          dest,
            relativeFilePath: fileName,
            timeText:         time,
            dateText:         dateStr,
            durationMs:       durationMs,
            width:            max(1, w),
            height:           max(1, h),
            texts:            [TextSegment()],
            startMs:          0,
            endMs:            durationMs,
            shotAtMillis:     Int64(actualDate.timeIntervalSince1970 * 1000)
        )
    }

    private func extractDateFromMetadata(metadata: [AVMetadataItem], fallbackDate: Date) -> Date {
        let creationItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierCreationDate)
        if let item = creationItems.first {
            if let dateVal = item.dateValue {
                return dateVal
            }
            if let strVal = item.stringValue, let parsed = parseDateString(strVal) {
                return parsed
            }
        }
        let qtItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .quickTimeMetadataCreationDate)
        if let item = qtItems.first {
            if let dateVal = item.dateValue {
                return dateVal
            }
            if let strVal = item.stringValue, let parsed = parseDateString(strVal) {
                return parsed
            }
        }
        return fallbackDate
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

    private func formatDate(_ date: Date) -> (String, String) {
        Formatters.clipTimeAndDate(date)
    }
}
