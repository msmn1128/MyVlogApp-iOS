import SwiftUI

/// 「動画を追加」「一時保存」「書き出し」の3ボタン。Android版ActionButtonsと同じ並び・見た目
/// （トナルの角丸ボタン2つの間に正円のアイコンボタンを挟む）。
struct ActionButtons: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var exportManager: ExportManager

    @Binding var showSavedProjects: Bool
    @Binding var showPhotoPicker:   Bool
    @Binding var showFilePicker:    Bool

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button { showPhotoPicker = true } label: {
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
                            postStartExport(includeTitle: true)
                        }
                        .onLongPressGesture(minimumDuration: 0.5) {
                            guard !store.clips.isEmpty else { return }
                            postStartExport(includeTitle: false)
                        }
                        // VoiceOver用のアクション（Android: ExportButtonのonClickLabel/onLongClickLabel相当）
                        .accessibilityLabel("書き出し")
                        .accessibilityAction {
                            guard !store.clips.isEmpty else { return }
                            postStartExport(includeTitle: true)
                        }
                        .accessibilityAction(named: "タイトルなしで書き出し") {
                            guard !store.clips.isEmpty else { return }
                            postStartExport(includeTitle: false)
                        }
                        .transition(.opacity)
                }
            }
            .animation(.default, value: exportManager.isExporting)
        }
    }

    private func postStartExport(includeTitle: Bool) {
        NotificationCenter.default.post(
            name: .startExport, object: nil,
            userInfo: ["includeTitle": includeTitle]
        )
    }
}

private extension View {
    /// Android FilledTonalButton相当。無効時はM3既定どおりonSurfaceの薄い塗り＋薄い文字にする
    /// （色つきのまま暗くするとdisabledに見えないため、無彩色に切り替える）
    func tonalPill(enabled: Bool, colorScheme: ColorScheme) -> some View {
        let onSurface = AppColors.onSurfaceVariant(colorScheme)
        return self
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? AppColors.onSecondaryContainer(colorScheme) : onSurface.opacity(0.38))
            .padding(.vertical, 12)
            .background(Capsule().fill(enabled ? AppColors.secondaryContainer(colorScheme) : onSurface.opacity(0.12)))
    }

    /// Android ExportButton相当。primary塗り＋onPrimary文字（他がトナルなのに対しここだけ強調）
    func primaryPill(enabled: Bool, colorScheme: ColorScheme) -> some View {
        let onSurface = AppColors.onSurfaceVariant(colorScheme)
        return self
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? AppColors.onPrimary(colorScheme) : onSurface.opacity(0.38))
            .padding(.vertical, 12)
            .background(Capsule().fill(enabled ? AppColors.primary(colorScheme) : onSurface.opacity(0.12)))
    }

    func tonalCircle(enabled: Bool, colorScheme: ColorScheme) -> some View {
        let onSurface = AppColors.onSurfaceVariant(colorScheme)
        return self
            .foregroundStyle(enabled ? AppColors.onSecondaryContainer(colorScheme) : onSurface.opacity(0.38))
            .frame(width: VlogLayout.toolbarButtonSize, height: VlogLayout.toolbarButtonSize)
            .background(Circle().fill(enabled ? AppColors.secondaryContainer(colorScheme) : onSurface.opacity(0.12)))
    }

    func outlinedPill(colorScheme: ColorScheme) -> some View {
        self
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppColors.primary(colorScheme))
            .padding(.vertical, 12)
            .overlay(Capsule().stroke(AppColors.outlineVariant(colorScheme), lineWidth: 1))
    }
}
