import SwiftUI

/// タイムラインの操作バー。Android版TimelineToolbarと同じ並び・アイコン・見た目にしてある。
/// 削除→全削除 | 前へ→後へ | ミュート→連続再生 | 戻す→進む | 2s→4s | 分割
struct OperationBar: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager

    @Binding var showDeleteAllAlert: Bool

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                let enabled = store.selectedClip != nil
                let trimPresetEnabled = enabled && (store.selectedClip?.durationMs ?? 0) > 0

                CompactIconButton(systemImage: "trash", contentDescription: "選択中のクリップを削除",
                                   enabled: enabled, tint: AppColors.error(colorScheme)) {
                    if let i = store.selectedIndex { store.deleteClip(at: i) }
                }
                CompactIconButton(systemImage: "trash.fill", contentDescription: "すべて削除",
                                   enabled: !store.clips.isEmpty, tint: AppColors.error(colorScheme)) {
                    showDeleteAllAlert = true
                }

                divider

                CompactIconButton(systemImage: "arrow.left", contentDescription: "ひとつ前へ移動",
                                   enabled: canMoveLeft) {
                    playerManager.pause(); store.moveClipLeft()
                }
                CompactIconButton(systemImage: "arrow.right", contentDescription: "ひとつ後ろへ移動",
                                   enabled: canMoveRight) {
                    playerManager.pause(); store.moveClipRight()
                }

                divider

                ToggleIconButton(
                    systemImage: store.timelineMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    checked: store.timelineMuted,
                    enabled: !store.clips.isEmpty
                ) { store.toggleTimelineMuted() }

                ToggleIconButton(
                    systemImage: "play.fill",
                    checked: store.isContinuousPlay,
                    enabled: !store.clips.isEmpty
                ) { store.toggleContinuousPlay() }

                divider

                CompactIconButton(systemImage: "arrow.uturn.backward", contentDescription: "もとに戻す",
                                   enabled: store.canUndo) { store.undo() }
                CompactIconButton(systemImage: "arrow.uturn.forward", contentDescription: "やり直す",
                                   enabled: store.canRedo) { store.redo() }

                divider

                TrimPresetButton(label: "2s", enabled: trimPresetEnabled) {
                    store.applyTrimPreset(lengthMs: 2_000)
                }
                TrimPresetButton(label: "4s", enabled: trimPresetEnabled) {
                    store.applyTrimPreset(lengthMs: 4_000)
                }

                divider

                splitButton
            }
        }
        .frame(height: VlogLayout.toolbarButtonSize)
    }

    // MARK: - Split/Unsplit

    private var splitButton: some View {
        let posMs  = playerManager.currentTimeMs
        let isNear = store.selectedClip?.splitPointNear(positionMs: posMs) != nil
        // "minus.bubble"はSF Symbolsに存在しない名前で、指定すると何も描画されず
        // アイコンが消えて見える不具合になっていた。"minus.bubble"の組み合わせ自体が
        // SF Symbolsに存在しないため、マイナス表記が要件なら"minus.circle.fill"
        // （実在確認済み）を使う。
        return CompactIconButton(
            systemImage: isNear ? "minus.circle.fill" : "plus.bubble",
            contentDescription: isNear ? "この区切りを解除" : "ここでひとことを分割",
            enabled: store.selectedIndex != nil,
            tint: AppColors.splitLine(colorScheme)
        ) {
            if isNear {
                store.removeSplitNear(positionMs: posMs)
            } else if let newIdx = store.splitAt(positionMs: posMs),
                      let clip = store.selectedClip {
                playerManager.seek(to: clip.texts[newIdx].startMs)
            }
        }
    }

    // MARK: - Helpers

    private var canMoveLeft:  Bool { (store.selectedIndex ?? 0) > 0 }
    private var canMoveRight: Bool {
        guard let i = store.selectedIndex else { return false }
        return i < store.clips.count - 1
    }

    private var divider: some View {
        Rectangle()
            .fill(AppColors.outlineVariant(colorScheme))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 2)
    }
}

/// Android CompactIconButton相当：正円の当たり判定、背景なし、無効時は38%に減光
private struct CompactIconButton: View {
    let systemImage: String
    let contentDescription: String
    var enabled: Bool = true
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: VlogLayout.toolbarIconSize * 0.82, weight: .regular))
                .foregroundStyle((tint ?? AppColors.onSurfaceVariant(colorScheme)).opacity(enabled ? 1 : 0.38))
                .frame(width: VlogLayout.toolbarButtonSize, height: VlogLayout.toolbarButtonSize)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(contentDescription)
    }
}

/// Android TimelineToggleButton相当：オンのときprimaryContainerで塗りつぶす正円ボタン
private struct ToggleIconButton: View {
    let systemImage: String
    let checked: Bool
    var enabled: Bool = true
    let action: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: VlogLayout.toolbarIconSize * 0.82, weight: .regular))
                .foregroundStyle(iconColor.opacity(enabled ? 1 : 0.38))
                .frame(width: VlogLayout.toolbarButtonSize, height: VlogLayout.toolbarButtonSize)
                .background(
                    Circle().fill(checked && enabled ? AppColors.primaryContainer(colorScheme) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var iconColor: Color {
        checked ? AppColors.onPrimaryContainer(colorScheme) : AppColors.onSurfaceVariant(colorScheme)
    }
}

/// Android TrimPresetButton相当：文字ラベル入りの角丸楕円（枠線のみ）
private struct TrimPresetButton: View {
    let label: String
    var enabled: Bool = true
    let action: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        let tint = AppColors.onSurfaceVariant(colorScheme).opacity(enabled ? 1 : 0.38)
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .frame(height: VlogLayout.toolbarButtonSize)
                .overlay(
                    Capsule().stroke(tint, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .padding(.horizontal, 3)
    }
}

extension Notification.Name {
    static let startExport = Notification.Name("startExport")
}
