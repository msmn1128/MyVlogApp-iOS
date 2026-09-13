import SwiftUI

/// Two-row toolbar with all clip-level operations.
struct OperationBar: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager

    @Binding var showSavedProjects:  Bool
    @Binding var showDeleteAllAlert: Bool
    @Binding var showPhotoPicker:    Bool
    @Binding var showFilePicker:     Bool

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            // ── Row 1: 追加 | 削除 全削除 | 保存 書き出し ──
            HStack(spacing: 0) {
                Menu {
                    Button { showPhotoPicker = true } label: {
                        Label("フォトライブラリ", systemImage: "photo.on.rectangle")
                    }
                    Button { showFilePicker = true } label: {
                        Label("ファイルから選択", systemImage: "folder")
                    }
                } label: {
                    barLabel(systemImage: "plus.circle", label: "追加")
                }
                .foregroundStyle(AppColors.primary)
                .frame(maxWidth: .infinity)

                groupDivider

                barButton(systemImage: "trash", label: "削除", tint: .red,
                          enabled: store.selectedIndex != nil) {
                    if let i = store.selectedIndex { store.deleteClip(at: i) }
                }
                barButton(systemImage: "trash.fill", label: "全削除", tint: .red,
                          enabled: !store.clips.isEmpty) {
                    showDeleteAllAlert = true
                }

                groupDivider

                barButton(systemImage: "tray.full", label: "保存") {
                    showSavedProjects = true
                }
                barButton(systemImage: "square.and.arrow.up", label: "書き出し",
                          enabled: !store.clips.isEmpty) {
                    NotificationCenter.default.post(name: .startExport, object: nil)
                }
            }
            .frame(height: 44)

            Divider()

            // ── Row 2: 連続再生 | 前へ 後へ | 戻す 進む | 分割/解除 ──
            HStack(spacing: 0) {
                Button {
                    store.toggleContinuousPlay()
                } label: {
                    barLabel(systemImage: "repeat",
                             label: "連続再生")
                }
                .foregroundStyle(store.isContinuousPlay ? AppColors.primary : Color.secondary)
                .frame(maxWidth: .infinity)

                groupDivider

                barButton(systemImage: "arrow.left", label: "前へ", enabled: canMoveLeft) {
                    playerManager.pause(); store.moveClipLeft()
                }
                barButton(systemImage: "arrow.right", label: "後へ", enabled: canMoveRight) {
                    playerManager.pause(); store.moveClipRight()
                }

                groupDivider

                barButton(systemImage: "arrow.uturn.backward", label: "戻す", enabled: store.canUndo) {
                    store.undo()
                }
                barButton(systemImage: "arrow.uturn.forward", label: "進む", enabled: store.canRedo) {
                    store.redo()
                }

                groupDivider

                splitButton
            }
            .frame(height: 44)
        }
    }

    // MARK: - Split/Unsplit

    private var splitButton: some View {
        let posMs  = playerManager.currentTimeMs
        let isNear = store.selectedClip?.splitPointNear(positionMs: posMs) != nil
        return barButton(
            systemImage: isNear ? "scissors.badge.arrow.left" : "scissors",
            label:       isNear ? "解除" : "分割",
            enabled:     store.selectedIndex != nil
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

    private var groupDivider: some View {
        Divider().frame(height: 24)
    }

    @ViewBuilder
    private func barLabel(systemImage: String, label: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage).font(.system(size: 16))
            Text(label).font(.system(size: 9))
        }
        .frame(minHeight: 36)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func barButton(
        systemImage: String,
        label: String,
        tint: Color = AppColors.primary,
        enabled: Bool = true,
        action: @escaping () -> Void = {}
    ) -> some View {
        Button(action: action) {
            barLabel(systemImage: systemImage, label: label)
        }
        .foregroundStyle(enabled ? tint : Color.secondary)
        .disabled(!enabled)
        .frame(maxWidth: .infinity)
    }
}

extension Notification.Name {
    static let startExport = Notification.Name("startExport")
}
