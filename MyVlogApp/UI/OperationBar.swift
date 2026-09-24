import SwiftUI

/// タイムラインの操作バー。Android版TimelineToolbarと同じ並び・アイコン・見た目にしてある。
/// 削除→全削除 | 前へ→後へ | ミュート→連続再生 | 戻す→進む | 2s→4s | 分割
struct OperationBar: View {
    @Environment(VlogStore.self) private var store
    @Environment(VideoPlayerManager.self) private var playerManager
    @Environment(ExportManager.self) private var exportManager

    @Environment(\.colorScheme) var colorScheme
    /// 中のボタンが文字サイズ設定で伸びるので、操作バーの高さも一緒に伸ばす
    /// （固定のままだとボタンが縦に潰れる）
    @ScaledMetric(relativeTo: .body) private var scaledBarHeight: CGFloat = VlogLayout.toolbarButtonSize
    private var barHeight: CGFloat { VlogLayout.cappedToolbarSize(scaledBarHeight) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 0) {
                // 書き出し中は編集させない（Android: TimelineToolbar の !isExporting）。書き出すのは
                // 押した時点の内容なので壊れはしないが、画面の編集と出来上がる動画が食い違って見える
                let editable = !exportManager.isExporting
                let hasClips = !store.clips.isEmpty && editable
                let enabled = store.selectedClip != nil && editable
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
                                   enabled: canMoveLeft && editable) {
                    playerManager.pause()
                    withAnimation { store.moveClipLeft() }
                }
                CompactIconButton(systemImage: "arrow.right", contentDescription: "ひとつ後ろへ移動",
                                   enabled: canMoveRight && editable) {
                    playerManager.pause()
                    withAnimation { store.moveClipRight() }
                }

                divider

                ToggleIconButton(
                    systemImage: store.timelineMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    checked: store.timelineMuted,
                    // オン/オフはVoiceOverがスイッチの状態として読むので、ここには書かない
                    contentDescription: "タイムラインのミュート（プレビューと書き出しの音を消します）",
                    enabled: hasClips
                ) { store.toggleTimelineMuted() }

                ToggleIconButton(
                    systemImage: "play.fill",
                    checked: store.isContinuousPlay,
                    contentDescription: "連続再生（オンなら終わったら次のクリップへ、オフならクリップの終わりで止まります）",
                    enabled: hasClips
                ) { store.toggleContinuousPlay() }

                divider

                CompactIconButton(systemImage: "arrow.uturn.backward", contentDescription: "もとに戻す",
                                   enabled: store.canUndo && editable) {
                    store.undo()
                    // 止めて、選択中のクリップの頭を出す（Android: applySnapshot）
                    playerManager.showSelectedClipStart()
                }
                CompactIconButton(systemImage: "arrow.uturn.forward", contentDescription: "やり直す",
                                   enabled: store.canRedo && editable) {
                    store.redo()
                    playerManager.showSelectedClipStart()
                }

                divider

                // 選択範囲の始まりを起点にする（先頭からではない）。読み上げのラベルも動作に合わせる
                TrimPresetButton(label: "2s", contentDescription: "選択範囲の始まりから2秒にする",
                                 enabled: trimPresetEnabled) {
                    store.applyTrimPreset(lengthMs: 2_000)
                    // 止めて選び直した範囲の頭を出す（Android: updateTrim → seekAndPause）
                    playerManager.showSelectedClipStart()
                }
                TrimPresetButton(label: "4s", contentDescription: "選択範囲の始まりから4秒にする",
                                 enabled: trimPresetEnabled) {
                    store.applyTrimPreset(lengthMs: 4_000)
                    playerManager.showSelectedClipStart()
                }

                divider

                SplitButton(enabled: enabled)
            }
        }
        // 収まりきらないときは、右端（よく使う2s/4sと分割）が見えた状態から始める。左端から始めると、
        // 押し間違えが怖い削除が見えていて、よく使う分割は横にずらさないと出てこなかった
        // （Android 0c56399。iPhoneの縦画面ではボタンが画面幅に収まらない）
        .defaultScrollAnchor(.trailing)
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
    /// 選択中のクリップがあり、書き出し中でないか（操作バーのほかのボタンと同じ判断）
    let enabled: Bool

    @Environment(VlogStore.self) private var store
    @Environment(VideoPlayerManager.self) private var playerManager
    @Environment(\.colorScheme) private var colorScheme
    /// 他のツールバーボタンと同じく、文字サイズ設定に合わせて当たり判定も広げる
    @ScaledMetric(relativeTo: .body) private var scaledButtonSize: CGFloat = VlogLayout.toolbarButtonSize
    private var buttonSize: CGFloat { VlogLayout.cappedToolbarSize(scaledButtonSize) }

    var body: some View {
        let posMs   = playerManager.currentTimeMs
        let isNear  = store.selectedClip?.splitPointNear(positionMs: posMs) != nil
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
