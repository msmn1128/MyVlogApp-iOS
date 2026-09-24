

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation
import Photos

struct ContentView: View {
    // storeはContentView+Import.swiftのextensionからも読み書きするためprivateを外してある
    // （photoItems等、他のextension分割と同じ方式）
    @Environment(VlogStore.self) var store
    @Environment(VideoPlayerManager.self) private var playerManager
    @Environment(ExportManager.self) private var exportManager

    // Layout
    @State private var isLandscape: Bool = false

    // Sheet / alert presentation
    @State private var showSavedProjects:  Bool = false
    @State private var showFilePicker:     Bool = false
    @State private var showPhotoPicker:    Bool = false
    @State private var showTitleDialog:    Bool = false

    // Photos import（ContentView+Import.swiftのインポート処理から読み書きするためinternal）
    @State var photoItems: [PhotosPickerItem] = []

    // Import progress（同上）。読み込み中かどうか（isImporting）だけはSavedProjectsViewからも
    // 見る必要があるためVlogStoreが持つ（Android: VlogViewModel.isAdding）
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

                // 保存/読み出しダイアログも他のオーバーレイと同じくフェードで出入りさせる
                if showSavedProjects {
                    SavedProjectsView(onDismiss: { showSavedProjects = false })
                        .transition(.opacity)
                }

                // 書き出し（タップ）を押した直後に出す、タイトルカード文言の選択ダイアログ
                if showTitleDialog {
                    TitleCreationDialogView(
                        defaultDateText: store.clips.first?.dateText ?? "",
                        onDismiss: { showTitleDialog = false },
                        // 自由入力が空（または空白だけ）なら先頭クリップの撮影日へ戻す判定は
                        // ExportManager.resolveTitleTextが持つので、ここは素通しでよい
                        onConfirm: { customTitleText in
                            showTitleDialog = false
                            exportManager.startExport(
                                clips: store.clips, timelineMuted: store.timelineMuted,
                                includeTitle: true, customTitleText: customTitleText
                            )
                        }
                    )
                    .transition(.opacity)
                }

                // 書き出しの完了・中止・失敗トーストを、通常のトースト（store）より優先して
                // 表示する（同時に出ることは想定していないが、書き出し結果を伝える方を優先）
                if let toast = exportManager.toastMessage ?? store.toastMessage {
                    ToastView(text: toast)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: exportManager.isExporting)
            .animation(.default, value: store.isImporting)
            .animation(.default, value: showSavedProjects)
            .animation(.default, value: showTitleDialog)
            .animation(.easeInOut(duration: 0.2), value: exportManager.toastMessage)
            .animation(.easeInOut(duration: 0.2), value: store.toastMessage)
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
        // 選択中のクリップが「別のもの」に変わったら読み込み直す。
        //
        // 監視するのはselectedIndexではなくクリップのid。indexは値が変わらないまま
        // 中身だけが入れ替わることがあり（選択中のクリップを削除するとselectedIndexは
        // 同じ番号のまま次のクリップを指す、一時保存の読み出しで0→0になる）、
        // indexで見ていると消えたクリップがAVPlayerに載ったまま再生され続けていた。
        // 波形（WaveformView）が元々.task(id: store.selectedClip?.id)で駆動しているのと揃える。
        .onChange(of: store.selectedClip?.id) { _, _ in
            if let clip = store.selectedClip {
                playerManager.loadClip(clip)
            } else {
                playerManager.reset()
            }
        }
        // トリム範囲の変更を再生側の終端監視へ反映する。
        //
        // 波形のドラッグは自分でupdateTrimBoundsを呼ぶが、トリムプリセット（2s/4s）と
        // もとに戻す・やり直しはstoreを書き換えるだけなので、ここで中継しないと
        // boundaryObserverが古い終端のまま残る（「2sにしたのに最後まで再生される」）。
        // clip全体ではなくtrimBoundsだけを見るのは、ひとことの1文字ごとに
        // 発火させないため（同じ理由で下のミュートもBoolだけに絞ってある）。
        .onChange(of: store.selectedClip?.trimBounds) { _, bounds in
            guard let bounds else { return }
            playerManager.updateTrimBounds(startMs: bounds.startMs, endMs: bounds.endMs)
        }
        // clips配列そのものをonChangeの対象にすると、ひとことを1文字打つたびに
        // 全クリップ（最大100本、それぞれtexts配列を持つ）の==比較が走るため、
        // 比較の対象は必要な値だけに絞る（クリップが空になった場合は上のidがnilになる経路で拾う）
        .onChange(of: store.selectedClip?.isMuted ?? false) {
            playerManager.applyMuteState(for: store.selectedClip)
        }
        .onChange(of: store.timelineMuted) {
            playerManager.applyMuteState(for: store.selectedClip)
        }
        // 書き出しが終わったら、動画が開けるかを確かめ直す。開けない動画が混ざっていて
        // 書き出しが断られたとき、どのタイルを外せばよいかを目印で示すため（Android: VlogViewModel）
        .onChange(of: exportManager.isExporting) { _, exporting in
            if !exporting { store.refreshMissingClips() }
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            setKeyboardVisible(true, note: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            setKeyboardVisible(false, note: note)
        }
        // Photo picker
        // photoLibrary: .shared() を渡さないとPhotosPickerItem.itemIdentifierが常にnilになり、
        // makeClipFromPH（PHAssetのメタデータだけを読む軽量パス）が一切使われず、
        // 選んだ動画every回VideoTransfer経由でフルクオリティのデータを丸ごとコピーする
        // 低速フォールバックに落ちてしまっていた（読み込みが極端に長くなる不具合の原因）
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      matching: .videos, preferredItemEncoding: .automatic,
                      photoLibrary: .shared())
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
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: size.width)

            ActionButtons(
                showSavedProjects: $showSavedProjects,
                showPhotoPicker:   $showPhotoPicker,
                showFilePicker:    $showFilePicker,
                showTitleDialog:   $showTitleDialog
            )
            .padding(.horizontal, 12)

            progressViews
                .padding(.horizontal, 12)

            timelineAndEditor()
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 10)
    }

    /// 動画の読み込みと書き出しの進捗（Android: AddProgress / ExportProgress）。操作ボタンの下に差し込む
    @ViewBuilder
    private var progressViews: some View {
        if store.isImporting {
            ImportProgressView(progress: importProgress, message: importMessage)
                .transition(.opacity)
        }
        if exportManager.isExporting {
            ExportProgressView()
                .transition(.opacity)
        }
    }

    /// Android: VlogAppScreen.timelineWeight / editorWeight（imeVisible=false）を正規化した比率
    private var timelineHeightRatio: CGFloat {
        let t: CGFloat = isKeyboardVisible ? 0.20 : 0.40
        let e: CGFloat = isKeyboardVisible ? 0.55 : 0.18
        return t / (t + e)
    }
    private var editorHeightRatio: CGFloat { 1 - timelineHeightRatio }

    /// タイムライン＋ひとこと欄。縦画面・横画面どちらでも同じ内容・比率なので共通化してある
    /// （末尾の左右paddingだけ呼び出し側で変える）。
    /// Android版の timelineWeight(0.40) : editorWeight(0.18) と同じ比率で
    /// 残り高さを配分する（キーボード非表示時の値）。
    private func timelineAndEditor() -> some View {
        GeometryReader { geo in
            let spacing: CGFloat = 10
            let available = max(0, geo.size.height - spacing)

            VStack(spacing: spacing) {
                TimelineView()
                    .frame(height: available * timelineHeightRatio)

                TextInputView()
                    .frame(height: available * editorHeightRatio)
            }
        }
    }

    private func landscapeLayout(size: CGSize) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                PreviewView()
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: size.width * 0.5)

                ActionButtons(
                    showSavedProjects: $showSavedProjects,
                    showPhotoPicker:   $showPhotoPicker,
                    showFilePicker:    $showFilePicker,
                    showTitleDialog:   $showTitleDialog
                )

                progressViews

                Spacer()
            }
            .padding(.leading, 12)
            .frame(width: size.width * 0.5)

            timelineAndEditor()
                .padding(.trailing, 12)
                .frame(width: size.width * 0.5)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Keyboard visibility

    /// キーボード表示状態の変化を受けて、タイムライン:ひとことの高さ比率を切り替える
    /// （timelineHeightRatio/editorHeightRatioが参照するisKeyboardVisibleの更新）。
    ///
    /// 以前はkeyboardWillChangeFrameを受けて「キーボードの上端が画面の高さより上か」で
    /// 判定していたが、その画面の高さを`UIScreen.main`から取っていた。マルチウィンドウや
    /// Stage Managerではアプリの領域と`UIScreen.main`の大きさが一致しないため、
    /// 判定がずれる。表示/非表示そのものを伝えるwillShow/willHideを使えば、
    /// 画面の大きさを知る必要がそもそも無い。
    private func setKeyboardVisible(_ visible: Bool, note: Notification) {
        guard visible != isKeyboardVisible else { return }
        // システムのキーボードアニメーションと同じ時間で比率を動かす。
        // 以前はここがwithAnimationで包まれておらず、比率がキーボードの
        // スライドと無関係に一瞬で切り替わっていた（Android版で
        // 「ひとこと」欄の枠が分割の瞬間に飛んで見えたのと同種の問題）。
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
        withAnimation(.easeInOut(duration: duration)) {
            isKeyboardVisible = visible
        }
    }
}

#Preview {
    ContentView()
        .environment(VlogStore())
        .environment(VideoPlayerManager())
        .environment(ExportManager())
}
