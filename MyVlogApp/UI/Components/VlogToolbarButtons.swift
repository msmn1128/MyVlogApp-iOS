import SwiftUI

// =====================================================================================
// OperationBar.swiftからの切り出し。タイムラインの操作バーで使う共通ボタン部品だけを
// まとめたもの（Android: ToolbarButtons.ktと同じ、共通コンポーネントの分離）。
// =====================================================================================

/// Android CompactIconButton相当：正円の当たり判定、背景なし、無効時は38%に減光。
/// onLongPressを渡すと長押しにも対応する（すべて削除など、確認ダイアログを出さない
/// 操作向け）。長押しが効いた瞬間はアイコンを一度縮めてからバウンドさせて戻し、
/// 実行された手応えを出す（Android版CompactIconButtonの弾む演出と同じ）
struct CompactIconButton: View {
    let systemImage: String
    let contentDescription: String
    var enabled: Bool = true
    var tint: Color? = nil
    var onLongPress: (() -> Void)? = nil
    var longPressAccessibilityLabel: String? = nil
    let action: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @State private var scale: CGFloat = 1
    /// 文字サイズ設定に合わせてボタンの当たり判定も広げる
    /// （アイコンだけ大きくして枠を固定にすると、はみ出して切れる）
    @ScaledMetric(relativeTo: .body) private var scaledButtonSize: CGFloat = VlogLayout.toolbarButtonSize
    /// 伸ばしすぎると操作バーが横に長くなりすぎるので上限をかける（VlogLayout.toolbarScaleCap）
    private var buttonSize: CGFloat { VlogLayout.cappedToolbarSize(scaledButtonSize) }

    var body: some View {
        Image(systemName: systemImage)
            .vlogFont(VlogLayout.toolbarIconSize * 0.82)
            .foregroundStyle((tint ?? AppColors.onSurfaceVariant(colorScheme)).opacity(enabled ? 1 : 0.38))
            // 有効/無効はundo/redoなど編集のたびに切り替わるため、色の濃淡を補間する
            .animation(.default, value: enabled)
            .scaleEffect(scale)
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                action()
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                guard enabled, let onLongPress else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                scale = 0.8
                withAnimation(.interpolatingSpring(stiffness: 300, damping: 12)) {
                    scale = 1
                }
                onLongPress()
            }
            // Buttonではなくジェスチャーで組んでいるので、無効状態は自分で伝える必要がある。
            // .disabled()を付けることでVoiceOverにも「使用できない」と読み上げられ、
            // 同時にタップ・長押しのジェスチャー自体も届かなくなる
            .disabled(!enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(contentDescription)
            .accessibilityAddTraits(.isButton)
            // 無効のときはカスタムアクションを登録しない。以前は登録したままで、
            // 画面上は押せないボタンがVoiceOverからだけ実行できてしまっていた
            .modifier(
                AccessibilityActionIfEnabled(enabled: enabled, action: action)
            )
            .modifier(
                LongPressAccessibilityAction(
                    label: longPressAccessibilityLabel, action: onLongPress, enabled: enabled
                )
            )
    }
}

/// 既定のアクセシビリティアクションを、有効なときだけ追加する
private struct AccessibilityActionIfEnabled: ViewModifier {
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction { action() }
        } else {
            content
        }
    }
}

/// アクセシビリティの長押し用アクションを、指定があって有効なときだけ追加する
private struct LongPressAccessibilityAction: ViewModifier {
    let label: String?
    let action: (() -> Void)?
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, let label, let action {
            content.accessibilityAction(named: label, action)
        } else {
            content
        }
    }
}

/// Android TimelineToggleButton相当：オンのときprimaryContainerで塗りつぶす正円ボタン
struct ToggleIconButton: View {
    let systemImage: String
    let checked: Bool
    let contentDescription: String
    var enabled: Bool = true
    let action: () -> Void

    @Environment(\.colorScheme) var colorScheme
    /// 文字サイズ設定に合わせて、塗りつぶす正円も一緒に伸ばす
    @ScaledMetric(relativeTo: .body) private var scaledButtonSize: CGFloat = VlogLayout.toolbarButtonSize
    /// 伸ばしすぎると操作バーが横に長くなりすぎるので上限をかける（VlogLayout.toolbarScaleCap）
    private var buttonSize: CGFloat { VlogLayout.cappedToolbarSize(scaledButtonSize) }

    var body: some View {
        // 背景・アイコン色の切り替わりも即時ではなくクロスフェードさせる
        // （Android版TimelineToggleButtonと同じ狙い）
        Button(action: action) {
            Image(systemName: systemImage)
                .vlogFont(VlogLayout.toolbarIconSize * 0.82)
                .foregroundStyle(iconColor.opacity(enabled ? 1 : 0.38))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: buttonSize, height: buttonSize)
                .background(
                    Circle().fill(checked && enabled ? AppColors.primaryContainer(colorScheme) : Color.clear)
                )
                .animation(.default, value: checked)
                .animation(.default, value: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(contentDescription)
        // オン/オフの状態はラベルの文言にも入っているが、トグルであることが
        // 読み上げの種別からも分かるようにする
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    private var iconColor: Color {
        checked ? AppColors.onPrimaryContainer(colorScheme) : AppColors.onSurfaceVariant(colorScheme)
    }
}

/// Android TrimPresetButton相当：文字ラベル入りの角丸楕円（枠線のみ）
struct TrimPresetButton: View {
    let label: String
    var enabled: Bool = true
    let action: () -> Void

    @Environment(\.colorScheme) var colorScheme
    /// 文字サイズ設定に合わせて、枠の高さも一緒に伸ばす
    @ScaledMetric(relativeTo: .body) private var scaledButtonHeight: CGFloat = VlogLayout.toolbarButtonSize
    /// 伸ばしすぎると操作バーが横に長くなりすぎるので上限をかける（VlogLayout.toolbarScaleCap）
    private var buttonHeight: CGFloat { VlogLayout.cappedToolbarSize(scaledButtonHeight) }

    var body: some View {
        // CompactIconButtonと同じく、有効/無効の切り替わりを色の濃淡で補間する
        let tint = AppColors.onSurfaceVariant(colorScheme).opacity(enabled ? 1 : 0.38)
        Button(action: action) {
            Text(label)
                .vlogFont(12, weight: .bold)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(height: buttonHeight)
                .overlay(
                    Capsule().stroke(tint, lineWidth: 1)
                )
                .animation(.default, value: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, 3)
    }
}

/// SF Symbolsに"minus.bubble"が無いため、"bubble"（吹き出し輪郭）に任意の記号を
/// 重ねて自作する。他のアイコンと同じ`.font(size:)`方式で"bubble"を描き、その上に
/// マイナスのバーを重ねることで、plus.bubbleと見た目のメトリクスを一致させている
/// （resizable().scaledToFit()でフレーム全体を埋める方式だと、SF Symbol側の
/// 内部余白ぶんだけ他のアイコンより微妙に大小がずれてしまうため使わない）。
struct BubbleGlyphIcon: View {
    enum Symbol { case minus }
    let symbol: Symbol
    var pointSize: CGFloat

    var body: some View {
        Image(systemName: "bubble")
            .vlogFont(pointSize)
            .overlay(
                Rectangle()
                    .frame(width: pointSize * 0.34, height: pointSize * 0.09)
                    // 吹き出しの尻尾ぶん下寄りな見た目にならないよう、本体中心を少し上へ
                    .offset(y: -pointSize * 0.1)
            )
    }
}
