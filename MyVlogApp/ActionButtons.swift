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
            }
            .disabled(exportManager.isExporting)

            Button {
                showSavedProjects = true
            } label: {
                Image(systemName: "doc.fill")
                    .font(.system(size: VlogLayout.toolbarIconSize * 0.82))
                    .tonalCircle(enabled: !exportManager.isExporting, colorScheme: colorScheme)
            }
            .disabled(exportManager.isExporting)
            .accessibilityLabel("編集内容の保存と読み出し")

            if exportManager.isExporting {
                Button {
                    exportManager.cancel()
                } label: {
                    Text("中止")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .outlinedPill(colorScheme: colorScheme)
                }
            } else {
                Button {
                    NotificationCenter.default.post(name: .startExport, object: nil)
                } label: {
                    Text("書き出し")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .tonalPill(enabled: !store.clips.isEmpty, colorScheme: colorScheme)
                }
                .disabled(store.clips.isEmpty)
            }
        }
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
