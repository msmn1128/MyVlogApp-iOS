import SwiftUI

// =====================================================================================
// Android版ToolbarButtons.ktの共通化と同じ狙い。以前はActionButtons.swiftと
// SavedProjectsView.swiftにtonalPillが一字一句同じ形で重複していたため、ここへ集約した。
// =====================================================================================

extension View {
    /// Android FilledTonalButton相当。無効時はM3既定どおりonSurfaceの薄い塗り＋薄い文字にする
    /// （色つきのまま暗くするとdisabledに見えないため、無彩色に切り替える）
    func tonalPill(enabled: Bool, colorScheme: ColorScheme) -> some View {
        self
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? AppColors.onSecondaryContainer(colorScheme) : disabledForeground(colorScheme))
            .padding(.vertical, 12)
            .background(Capsule().fill(enabled ? AppColors.secondaryContainer(colorScheme) : disabledBackground(colorScheme)))
    }

    /// Android ExportButton相当。primary塗り＋onPrimary文字（他がトナルなのに対しここだけ強調）
    func primaryPill(enabled: Bool, colorScheme: ColorScheme) -> some View {
        self
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(enabled ? AppColors.onPrimary(colorScheme) : disabledForeground(colorScheme))
            .padding(.vertical, 12)
            .background(Capsule().fill(enabled ? AppColors.primary(colorScheme) : disabledBackground(colorScheme)))
    }

    func tonalCircle(enabled: Bool, colorScheme: ColorScheme) -> some View {
        self
            .foregroundStyle(enabled ? AppColors.onSecondaryContainer(colorScheme) : disabledForeground(colorScheme))
            .frame(width: VlogLayout.toolbarButtonSize, height: VlogLayout.toolbarButtonSize)
            .background(Circle().fill(enabled ? AppColors.secondaryContainer(colorScheme) : disabledBackground(colorScheme)))
    }

    func outlinedPill(colorScheme: ColorScheme) -> some View {
        self
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(AppColors.primary(colorScheme))
            .padding(.vertical, 12)
            .overlay(Capsule().stroke(AppColors.outlineVariant(colorScheme), lineWidth: 1))
    }
}

/// M3のdisabled既定: 文字38%・面12%のonSurface。色つきのまま暗くするとdisabledに
/// 見えないため無彩色へ切り替える（tonalPill/primaryPill/tonalCircleで共通の式だった
/// ものを1箇所にまとめた）
private func disabledForeground(_ scheme: ColorScheme) -> Color {
    AppColors.onSurfaceVariant(scheme).opacity(0.38)
}

private func disabledBackground(_ scheme: ColorScheme) -> Color {
    AppColors.onSurfaceVariant(scheme).opacity(0.12)
}
