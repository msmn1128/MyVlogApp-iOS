



import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
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

struct ContentView: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager
    @EnvironmentObject var exportManager: ExportManager

    // Layout
    @State private var isLandscape: Bool = false

    // Sheet / alert presentation
    @State private var showSavedProjects:  Bool = false
    @State private var showFilePicker:     Bool = false
    @State private var showPhotoPicker:    Bool = false

    // Photos import
    @State private var photoItems: [PhotosPickerItem] = []

    // Import progress
    @State private var isImporting:    Bool   = false
    @State private var importProgress: Double = 0.0
    @State private var importMessage:  String = ""

    // キーボード表示中はひとこと欄を広げる（Android: VlogAppScreen imeVisible分岐）
    @State private var isKeyboardVisible: Bool = false

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        GeometryReader { geo in
            let sz = geo.size
            ZStack {
                AppColors.background(colorScheme).ignoresSafeArea()

                if isLandscape {
                    landscapeLayout(size: sz)
                } else {
                    portraitLayout(size: sz)
                }

                if isImporting {
                    ImportOverlayView(progress: importProgress, message: importMessage)
                }

                if exportManager.isExporting {
                    ExportOverlayView().environmentObject(exportManager)
                }

                if showSavedProjects {
                    SavedProjectsView(onDismiss: { showSavedProjects = false })
                        .environmentObject(store)
                }

                if let toast = store.toastMessage {
                    ToastView(text: toast)
                }
            }
            .onChange(of: sz) { _, newSz in
                isLandscape = newSz.width > newSz.height
            }
            .onAppear { isLandscape = sz.width > sz.height }
        }
        // Load clip when selection changes
        .onChange(of: store.selectedIndex) {
            if let clip = store.selectedClip {
                playerManager.loadClip(clip)
            } else {
                playerManager.reset()
            }
        }
        .onChange(of: store.clips) {
            if store.clips.isEmpty {
                playerManager.reset()
            } else {
                playerManager.applyMuteState(for: store.selectedClip)
            }
        }
        .onChange(of: store.timelineMuted) {
            playerManager.applyMuteState(for: store.selectedClip)
        }
        // キーボード表示中はタイムライン:ひとことの比率をAndroid版のimeVisible分岐に合わせて変える
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        // Export trigger
        .onReceive(NotificationCenter.default.publisher(for: .startExport)) { note in
            let includeTitle = (note.userInfo?["includeTitle"] as? Bool) ?? true
            exportManager.startExport(clips: store.clips, timelineMuted: store.timelineMuted, includeTitle: includeTitle)
        }
        // Photo picker
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      matching: .videos, preferredItemEncoding: .automatic)
        .onChange(of: photoItems) { _, items in
            Task { await handlePhotosPick(items) }
        }
        // File importer
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.movie, .video, .quickTimeMovie, .mpeg4Movie],
            allowsMultipleSelection: true
        ) { result in
            Task { await handleFilePick(result) }
        }
    }

    // MARK: - Layout builders

    private func portraitLayout(size: CGSize) -> some View {
        VStack(spacing: 10) {
            PreviewView()
                .environmentObject(store)
                .environmentObject(playerManager)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: size.width)

            ActionButtons(
                showSavedProjects: $showSavedProjects,
                showPhotoPicker:   $showPhotoPicker,
                showFilePicker:    $showFilePicker
            )
            .environmentObject(store)
            .environmentObject(exportManager)
            .padding(.horizontal, 12)

            // Android版の timelineWeight(0.40) : editorWeight(0.18) と同じ比率で
            // 残り高さを配分する（キーボード非表示時の値）。
            GeometryReader { geo in
                let spacing: CGFloat = 10
                let available = max(0, geo.size.height - spacing)
                let timelineHeight = available * timelineHeightRatio
                let editorHeight   = available * editorHeightRatio

                VStack(spacing: spacing) {
                    TimelineView()
                        .environmentObject(store)
                        .environmentObject(playerManager)
                        .frame(height: timelineHeight)

                    TextInputView()
                        .environmentObject(store)
                        .environmentObject(playerManager)
                        .frame(height: editorHeight)
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 10)
    }

    /// Android: VlogAppScreen.timelineWeight / editorWeight（imeVisible=false）を正規化した比率
    private var timelineHeightRatio: CGFloat {
        let t: CGFloat = isKeyboardVisible ? 0.20 : 0.40
        let e: CGFloat = isKeyboardVisible ? 0.55 : 0.18
        return t / (t + e)
    }
    private var editorHeightRatio: CGFloat { 1 - timelineHeightRatio }

    private func landscapeLayout(size: CGSize) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                PreviewView()
                    .environmentObject(store)
                    .environmentObject(playerManager)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: size.width * 0.5)

                ActionButtons(
                    showSavedProjects: $showSavedProjects,
                    showPhotoPicker:   $showPhotoPicker,
                    showFilePicker:    $showFilePicker
                )
                .environmentObject(store)
                .environmentObject(exportManager)

                Spacer()
            }
            .padding(.leading, 12)
            .frame(width: size.width * 0.5)

            GeometryReader { geo in
                let spacing: CGFloat = 10
                let available = max(0, geo.size.height - spacing)

                VStack(spacing: spacing) {
                    TimelineView()
                        .environmentObject(store)
                        .environmentObject(playerManager)
                        .frame(height: available * timelineHeightRatio)

                    TextInputView()
                        .environmentObject(store)
                        .environmentObject(playerManager)
                        .frame(height: available * editorHeightRatio)
                }
            }
            .padding(.trailing, 12)
            .frame(width: size.width * 0.5)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Import handlers

    private func handlePhotosPick(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isImporting = true
        importProgress = 0.0
        importMessage = "動画を読み込み中 (0/\(items.count))..."

        let total = items.count
        var loadedClips: [(index: Int, clip: VlogClip)] = []

        await withTaskGroup(of: (Int, VlogClip?).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    if let id = item.itemIdentifier, let clip = await self.makeClipFromPH(identifier: id) {
                        return (index, clip)
                    } else if let transfer = try? await item.loadTransferable(type: VideoTransfer.self),
                              let clip = await self.makeClipFromURL(transfer.url, isTemporaryFile: true) {
                        return (index, clip)
                    }
                    return (index, nil)
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

        photoItems = []
        if !newClips.isEmpty { store.addClips(newClips) }
        let skipped = items.count - newClips.count
        if skipped > 0 {
            store.showMessage("\(skipped) 件の動画は長さを取得できませんでした")
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        isImporting = false
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

    private func handleFilePick(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, !urls.isEmpty else { return }
        isImporting = true
        importProgress = 0.0
        importMessage = "動画を読み込み中 (0/\(urls.count))..."

        let total = urls.count
        var loadedClips: [(index: Int, clip: VlogClip)] = []

        await withTaskGroup(of: (Int, VlogClip?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    _ = url.startAccessingSecurityScopedResource()
                    defer { url.stopAccessingSecurityScopedResource() }
                    let clip = await self.makeClipFromURL(url, isTemporaryFile: false)
                    return (index, clip)
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
        let skipped = urls.count - newClips.count
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
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let df = DateFormatter(); df.dateFormat = "yyyy/MM/dd"
        return (tf.string(from: date), df.string(from: date))
    }
}

// MARK: - Toast（Android: Toast相当の一時的な通知）

struct ToastView: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 24)
                .padding(.horizontal, 24)
                .transition(.opacity)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: text)
    }
}

// MARK: - Import overlay

struct ImportOverlayView: View {
    let progress: Double
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(AppColors.primary)
                    .frame(width: 260)
                Text(message)
                    .foregroundStyle(.white)
                    .font(.subheadline)
            }
            .padding(28)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

// MARK: - Export overlay

struct ExportOverlayView: View {
    @EnvironmentObject var exportManager: ExportManager
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: exportManager.progress)
                    .progressViewStyle(.linear).tint(AppColors.primary).frame(width: 260)
                Text(exportManager.message)
                    .foregroundStyle(.white).font(.subheadline)
                Button("中止") { exportManager.cancel() }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(Color.red.opacity(0.85)).clipShape(Capsule())
            }
            .padding(28)
            .background(.regularMaterial).clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(VlogStore())
        .environmentObject(VideoPlayerManager())
        .environmentObject(ExportManager())
}
