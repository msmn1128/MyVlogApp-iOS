import SwiftUI
import Photos

/// 「動画を追加」「一時保存」「書き出し」の3ボタン。Android版ActionButtonsと同じ並び・見た目
/// （トナルの角丸ボタン2つの間に正円のアイコンボタンを挟む）。
struct ActionButtons: View {
    @Environment(VlogStore.self) private var store
    @Environment(ExportManager.self) private var exportManager

    @Binding var showSavedProjects: Bool
    @Binding var showPhotoPicker:   Bool
    @Binding var showFilePicker:    Bool
    @Binding var showTitleDialog:   Bool

    @Environment(\.colorScheme) var colorScheme

    /// 「動画を追加」と保存。読み込み中に押し直すと同じ動画を並行して読むことになり、
    /// 読み込み中のタイムラインは途中の状態なので保存も読み出しもさせない（Android: ActionButtons）
    private var canEdit: Bool { !exportManager.isExporting && !store.isImporting }
    /// 書き出し。読み込み中の動画はまだタイムラインに入っていないので、その間は始めさせない
    private var canExport: Bool { !store.clips.isEmpty && !store.isImporting }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button { openPhotoPicker() } label: {
                    Label("フォトライブラリ", systemImage: "photo.on.rectangle")
                }
                Button { showFilePicker = true } label: {
                    Label("ファイルから選択", systemImage: "folder")
                }
            } label: {
                Text("動画を追加")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .tonalPill(enabled: canEdit, colorScheme: colorScheme)
                    .animation(.default, value: canEdit)
            }
            .disabled(!canEdit)

            Button {
                showSavedProjects = true
            } label: {
                Image(systemName: "doc.fill")
                    .vlogFont(VlogLayout.toolbarIconSize * 0.82)
                    .tonalCircle(enabled: canEdit, colorScheme: colorScheme)
                    .animation(.default, value: canEdit)
            }
            .disabled(!canEdit)
            .accessibilityLabel("編集内容の保存と読み出し")

            // 書き出し⇔中止の入れ替わりが瞬時に切り替わらず、フェードで橋渡しする
            // （Android版ActionButtonsのAnimatedContentと同じ狙い）
            Group {
                if exportManager.isExporting {
                    Button {
                        exportManager.cancel()
                    } label: {
                        Text("中止")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .outlinedPill(colorScheme: colorScheme)
                    }
                    .transition(.opacity)
                } else {
                    // Android版ExportButtonと同じく、タップ=タイトルカードあり、長押し=タイトルカードなし。
                    // Buttonのタップとカスタムの長押しジェスチャーを同居させると発火順序が不安定になり
                    // 長押し側が誤ってタイトルカード無しのまま素通りする事故があったため、Buttonではなく
                    // onTapGesture/onLongPressGestureの組み合わせ（SwiftUI標準の曖昧さ解消）にしている。
                    Text("書き出し")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        // Android版ExportButtonは動画を追加と違いprimary塗り（主役の操作として強調）
                        .primaryPill(enabled: canExport, colorScheme: colorScheme)
                        .animation(.default, value: canExport)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard canExport else { return }
                            showTitleDialog = true
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            guard canExport else { return }
                            exportManager.startExport(clips: store.clips, timelineMuted: store.timelineMuted, includeTitle: false)
                        }
                        // クリップが無いときは押せない。見た目（primaryPillのenabled）だけでなく
                        // 実際に無効化しておくことで、VoiceOverにも「使用できない」と伝わる
                        .disabled(!canExport)
                        // VoiceOver用のラベルとアクション（Android: ExportButtonのonClickLabel/onLongClickLabel相当）。
                        // Buttonではなくジェスチャーで組んでいるので、ボタンであることは自分で伝える
                        .accessibilityLabel("書き出し")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction {
                            guard canExport else { return }
                            showTitleDialog = true
                        }
                        .accessibilityAction(named: "タイトルなしで書き出し") {
                            guard canExport else { return }
                            exportManager.startExport(clips: store.clips, timelineMuted: store.timelineMuted, includeTitle: false)
                        }
                        .transition(.opacity)
                }
            }
            .animation(.default, value: exportManager.isExporting)
        }
    }

    /// フォトライブラリへの読み取り権限を先にリクエストしてからピッカーを開く。
    /// これをしないとPhotosPickerItem.itemIdentifierがあってもPHAsset.fetchAssets(withLocalIdentifiers:)
    /// がアプリ側で解決できず、ContentView+Import.swiftの高速パス（makeClipFromPH）が
    /// 一切使われずに毎回フルクオリティのデータ転送（VideoTransfer）へ落ちてしまい、
    /// 動画追加が極端に遅くなる（進捗バーもほとんど進まなくなる）原因になっていた。
    /// 権限が既に確定済みの場合はダイアログなしで即座に返るので、通常は待たされない。
    private func openPhotoPicker() {
        Task {
            _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            showPhotoPicker = true
        }
    }
}

