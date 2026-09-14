

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import Photos

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

    // Photos import（ContentView+Import.swiftのインポート処理から読み書きするためinternal）
    @State var photoItems: [PhotosPickerItem] = []

    // Import progress（同上）
    @State var isImporting:    Bool   = false
    @State var importProgress: Double = 0.0
    @State var importMessage:  String = ""

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
        }
        // isLandscapeの判定は、ソフトキーボード表示中にGeometryReaderの高さが
        // 縮む影響を受けないよう、キーボード分のセーフエリアを無視した専用の
        // GeometryReaderで測る。上のsz（bodyの主レイアウトに使う値）はキーボード
        // 表示中も普通に縮めておき、既存のキーボード用の高さ比率調整を維持する。
        //
        // 以前はキーボード表示通知（isKeyboardVisible）が来るまでの短い間に
        // sizeの変化がisLandscapeを誤って書き換えてしまうことがあった
        // （iPadの縦画面でキーボードを開くと2カラム表示になる不具合）。
        // 通知とレイアウト更新の順序はSwiftUI側の保証がなく、フラグでの
        // ガードでは順序次第で防ぎきれないため、そもそもキーボードの影響を
        // 受けないサイズで判定する方式にした。
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { isLandscape = geo.size.width > geo.size.height }
                    .onChange(of: geo.size) { _, newSize in
                        isLandscape = newSize.width > newSize.height
                    }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        )
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
        // キーボード表示中はタイムライン:ひとことの比率をAndroid版のimeVisible分岐に合わせて変える。
        //
        // 以前は縦画面で「ひとこと」にフォーカス中はプレビュー・タイムラインを丸ごと隠して
        // 入力欄だけを全画面表示する専用モード（isEditingHitokoto）を持っていたが、
        // これを@FocusStateの変化から間接的に（コールバック経由で）更新する設計は、
        // 画面回転などのタイミングでフォーカスの実状態とずれて固まることがあり、
        // 「キーボードを閉じてもひとこと欄だけが全画面に残る」という不具合の原因になっていた。
        // 縦画面でも常に1カラム（プレビュー・タイムライン・ひとこと欄すべて表示）を保つことで、
        // この種のズレが起きようがない構造にする。
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screenHeight = UIScreen.main.bounds.height
            isKeyboardVisible = frame.origin.y < screenHeight
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
        // 縦画面は常に1カラム（プレビュー・タイムライン・ひとこと欄すべて表示）を保つ。
        // キーボード表示中はAndroid版のimeVisible分岐と同じ比率でタイムライン:ひとことの
        // 高さ配分だけを変える（セクションの着脱はしない）。
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
