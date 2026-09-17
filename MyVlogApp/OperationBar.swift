import SwiftUI

/// タイムラインの操作バー。Android版TimelineToolbarと同じ並び・アイコン・見た目にしてある。
/// 削除→全削除 | 前へ→後へ | ミュート→連続再生 | 戻す→進む | 2s→4s | 分割
struct OperationBar: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                let enabled = store.selectedClip != nil
                let trimPresetEnabled = enabled && (store.selectedClip?.durationMs ?? 0) > 0

                // タップ＝選択中のクリップだけ削除、長押し＝すべて削除。
                // どちらも押し間違えたら「もとに戻す」で復帰できるので、確認ダイアログは出さない
                // （Android版と同じくtrash/trash.fillの2ボタン構成をやめて1つに統合した）
                CompactIconButton(systemImage: "trash", contentDescription: "選択中のクリップを削除",
                                   enabled: enabled, tint: AppColors.error(colorScheme),
                                   onLongPress: { withAnimation { store.deleteAllClips() } },
                                   longPressAccessibilityLabel: "すべて削除") {
                    // 削除・並べ替えで前後のタイルが瞬間移動せず、新しい位置へ滑らかに
                    // スライドするようにする（Android版のLazyRow+animateItem()と同じ狙い）
                    withAnimation {
                        if let i = store.selectedIndex { store.deleteClip(at: i) }
                    }
                }

                divider

                CompactIconButton(systemImage: "arrow.left", contentDescription: "ひとつ前へ移動",
                                   enabled: canMoveLeft) {
                    playerManager.pause()
                    withAnimation { store.moveClipLeft() }
                }
                CompactIconButton(systemImage: "arrow.right", contentDescription: "ひとつ後ろへ移動",
                                   enabled: canMoveRight) {
                    playerManager.pause()
                    withAnimation { store.moveClipRight() }
                }

                divider

                ToggleIconButton(
                    systemImage: store.timelineMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    checked: store.timelineMuted,
                    contentDescription: store.timelineMuted
                        ? "タイムラインのミュート：オン（プレビューと書き出しの音を消します）"
                        : "タイムラインのミュート：オフ",
                    enabled: !store.clips.isEmpty
                ) { store.toggleTimelineMuted() }

                ToggleIconButton(
                    systemImage: "play.fill",
                    checked: store.isContinuousPlay,
                    contentDescription: store.isContinuousPlay
                        ? "連続再生：オン（終わったら次のクリップへ進みます）"
                        : "連続再生：オフ（クリップの終わりで止まります）",
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
        let enabled = store.selectedIndex != nil
        let tint = AppColors.splitLine(colorScheme)

        return Button {
            if isNear {
                store.removeSplitNear(positionMs: posMs)
            } else if let newIdx = store.splitAt(positionMs: posMs),
                      let clip = store.selectedClip {
                playerManager.seek(to: clip.texts[newIdx].startMs)
            }
        } label: {
            Group {
                if isNear {
                    // "minus.bubble"はSF Symbolsに存在しないため、"plus.bubble"と
                    // 同じ吹き出しの中身だけマイナスに差し替えた自作アイコンにしている。
                    BubbleGlyphIcon(symbol: .minus, pointSize: VlogLayout.toolbarIconSize * 0.82)
                } else {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: VlogLayout.toolbarIconSize * 0.82, weight: .regular))
                }
            }
            .foregroundStyle(tint.opacity(enabled ? 1 : 0.38))
            .frame(width: VlogLayout.toolbarButtonSize, height: VlogLayout.toolbarButtonSize)
            .animation(.default, value: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(isNear ? "この区切りを解除" : "ここでひとことを分割（動画は切りません）")
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

// CompactIconButton/ToggleIconButton/TrimPresetButton/BubbleGlyphIconはVlogToolbarButtons.swiftへ
// 切り出してある（Android: ToolbarButtons.ktと同じ、共通ボタン部品の分離）。
