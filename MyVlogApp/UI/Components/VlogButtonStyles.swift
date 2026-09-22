import SwiftUI

// =====================================================================================
// Android版ToolbarButtons.ktの共通化と同じ狙い。以前はActionButtons.swiftと
// SavedProjectsView.swiftにtonalPillが一字一句同じ形で重複していたため、ここへ集約した。
//
// 中身をViewModifierにしてあるのは、`@ScaledMetric`（Dynamic Typeの倍率）を持てるのが
// Viewだけだから。`extension View`の素の関数では文字サイズ設定に追従できず、
// 文字だけ大きくなって入れ物が固定のまま……という切れ方をする。
// =====================================================================================

/// Android FilledTonalButton相当。無効時はM3既定どおりonSurfaceの薄い塗り＋薄い文字にする
/// （色つきのまま暗くするとdisabledに見えないため、無彩色に切り替える）
private struct TonalPill: ViewModifier {
    let enabled: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .vlogFont(14, weight: .semibold)
            .foregroundStyle(enabled ? AppColors.onSecondaryContainer(colorScheme) : disabledForeground(colorScheme))
            .padding(.vertical, 12)
            .background(Capsule().fill(enabled ? AppColors.secondaryContainer(colorScheme) : disabledBackground(colorScheme)))
    }
}

/// Android ExportButton相当。primary塗り＋onPrimary文字（他がトナルなのに対しここだけ強調）
private struct PrimaryPill: ViewModifier {
    let enabled: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .vlogFont(14, weight: .semibold)
            .foregroundStyle(enabled ? AppColors.onPrimary(colorScheme) : disabledForeground(colorScheme))
            .padding(.vertical, 12)
            .background(Capsule().fill(enabled ? AppColors.primary(colorScheme) : disabledBackground(colorScheme)))
    }
}

/// 正円のアイコンボタン。文字サイズ設定に合わせて直径も伸ばす
/// （中のアイコンだけ大きくして円を固定にすると、アイコンが円からはみ出す）
private struct TonalCircle: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var scaledDiameter: CGFloat = VlogLayout.toolbarButtonSize
    private var diameter: CGFloat { VlogLayout.cappedToolbarSize(scaledDiameter) }

    let enabled: Bool
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .foregroundStyle(enabled ? AppColors.onSecondaryContainer(colorScheme) : disabledForeground(colorScheme))
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(enabled ? AppColors.secondaryContainer(colorScheme) : disabledBackground(colorScheme)))
    }
}

private struct OutlinedPill: ViewModifier {
    let colorScheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .vlogFont(14, weight: .semibold)
            .foregroundStyle(AppColors.primary(colorScheme))
            .padding(.vertical, 12)
            .overlay(Capsule().stroke(AppColors.outline(colorScheme), lineWidth: 1))
    }
}

extension View {
    func tonalPill(enabled: Bool, colorScheme: ColorScheme) -> some View {
        modifier(TonalPill(enabled: enabled, colorScheme: colorScheme))
    }

    func primaryPill(enabled: Bool, colorScheme: ColorScheme) -> some View {
        modifier(PrimaryPill(enabled: enabled, colorScheme: colorScheme))
    }

    func tonalCircle(enabled: Bool, colorScheme: ColorScheme) -> some View {
        modifier(TonalCircle(enabled: enabled, colorScheme: colorScheme))
    }

    func outlinedPill(colorScheme: ColorScheme) -> some View {
        modifier(OutlinedPill(colorScheme: colorScheme))
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
