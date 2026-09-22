import SwiftUI

/// タイムラインの操作バー。Android版TimelineToolbarと同じ並び・アイコン・見た目にしてある。
/// 削除→全削除 | 前へ→後へ | ミュート→連続再生 | 戻す→進む | 2s→4s | 分割
struct OperationBar: View {
    @Environment(VlogStore.self) private var store
    @Environment(VideoPlayerManager.self) private var playerManager

    @Environment(\.colorScheme) var colorScheme
    /// 中のボタンが文字サイズ設定で伸びるので、操作バーの高さも一緒に伸ばす
    /// （固定のままだとボタンが縦に潰れる）
    @ScaledMetric(relativeTo: .body) private var scaledBarHeight: CGFloat = VlogLayout.toolbarButtonSize
    private var barHeight: CGFloat { VlogLayout.cappedToolbarSize(scaledBarHeight) }

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

                SplitButton()
            }
        }
        .frame(height: barHeight)
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

// MARK: - 分割/解除ボタン

/// ひとことの分割（＋）と、区切りの解除（−）を再生位置に応じて出し分けるボタン。
///
/// 操作バー本体から独立した葉にしてあるのは、再生位置（約33msごとに変わる）を
/// 読むのがこのボタンだけだから。`OperationBar`のbodyで読むと、Observationが
/// 操作バー全体（ボタン10個ぶん）を依存として記録し、再生中ずっと毎秒30回
/// 作り直される（Android版が`derivedStateOf`で「区切りの上か」だけに絞っているのと同じ狙い）。
private struct SplitButton: View {
    @Environment(VlogStore.self) private var store
    @Environment(VideoPlayerManager.self) private var playerManager
    @Environment(\.colorScheme) private var colorScheme
    /// 他のツールバーボタンと同じく、文字サイズ設定に合わせて当たり判定も広げる
    @ScaledMetric(relativeTo: .body) private var scaledButtonSize: CGFloat = VlogLayout.toolbarButtonSize
    private var buttonSize: CGFloat { VlogLayout.cappedToolbarSize(scaledButtonSize) }

    var body: some View {
        let posMs   = playerManager.currentTimeMs
        let isNear  = store.selectedClip?.splitPointNear(positionMs: posMs) != nil
        let enabled = store.selectedIndex != nil
        let tint    = AppColors.splitLine(colorScheme)

        Button {
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
                        .vlogFont(VlogLayout.toolbarIconSize * 0.82, weight: .regular)
                }
            }
            .foregroundStyle(tint.opacity(enabled ? 1 : 0.38))
            .frame(width: buttonSize, height: buttonSize)
            .animation(.default, value: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(isNear ? "この区切りを解除" : "ここでひとことを分割（動画は切りません）")
    }
}

// CompactIconButton/ToggleIconButton/TrimPresetButton/BubbleGlyphIconはVlogToolbarButtons.swiftへ
// 切り出してある（Android: ToolbarButtons.ktと同じ、共通ボタン部品の分離）。
