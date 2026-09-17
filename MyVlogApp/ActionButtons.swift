import SwiftUI
import Photos

/// 「動画を追加」「一時保存」「書き出し」の3ボタン。Android版ActionButtonsと同じ並び・見た目
/// （トナルの角丸ボタン2つの間に正円のアイコンボタンを挟む）。
struct ActionButtons: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var exportManager: ExportManager

    @Binding var showSavedProjects: Bool
    @Binding var showPhotoPicker:   Bool
    @Binding var showFilePicker:    Bool
    @Binding var showTitleDialog:   Bool

    @Environment(\.colorScheme) var colorScheme

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
                    .tonalPill(enabled: !exportManager.isExporting, colorScheme: colorScheme)
                    .animation(.default, value: exportManager.isExporting)
            }
            .disabled(exportManager.isExporting)

            Button {
                showSavedProjects = true
            } label: {
                Image(systemName: "doc.fill")
                    .font(.system(size: VlogLayout.toolbarIconSize * 0.82))
                    .tonalCircle(enabled: !exportManager.isExporting, colorScheme: colorScheme)
                    .animation(.default, value: exportManager.isExporting)
            }
            .disabled(exportManager.isExporting)
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
                        .primaryPill(enabled: !store.clips.isEmpty, colorScheme: colorScheme)
                        .animation(.default, value: store.clips.isEmpty)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !store.clips.isEmpty else { return }
                            showTitleDialog = true
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            guard !store.clips.isEmpty else { return }
                            exportManager.startExport(clips: store.clips, timelineMuted: store.timelineMuted, includeTitle: false)
                        }
                        // VoiceOver用のアクション（Android: ExportButtonのonClickLabel/onLongClickLabel相当）
                        .accessibilityLabel("書き出し")
                        .accessibilityAction {
                            guard !store.clips.isEmpty else { return }
                            showTitleDialog = true
                        }
                        .accessibilityAction(named: "タイトルなしで書き出し") {
                            guard !store.clips.isEmpty else { return }
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

