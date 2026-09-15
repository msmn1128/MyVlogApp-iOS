import SwiftUI

/// 「編集内容の保存」ダイアログ。Android版SaveLoadDialogと同じ、中央カード＋暗幕オーバーレイで
/// 保存・上書き・読み出し・削除をまとめる。
struct SavedProjectsView: View {
    @EnvironmentObject var store: VlogStore
    @Environment(\.colorScheme) var colorScheme
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var pendingDelete: SavedProject? = nil
    @State private var showLimitAlert: Bool = false

    private var canSave: Bool { !store.clips.isEmpty }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                    .padding(.top, 24)

                Text("編集内容の保存")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text("保存名")
                        .font(.system(size: 11))
                        .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppColors.outlineVariant(colorScheme), lineWidth: 1)
                        )
                        .disabled(!canSave)
                }

                Button {
                    // 名前が空のときの既定値は「無題」ではなくAndroid版と同じ保存日時にする
                    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let resolvedName = trimmedName.isEmpty
                        ? Formatters.savedAtLabel(msSinceEpoch: Int64(Date().timeIntervalSince1970 * 1000))
                        : trimmedName
                    if store.saveCurrentProject(name: resolvedName) {
                        name = nextDefaultName()
                    } else {
                        showLimitAlert = true
                    }
                } label: {
                    Text("この内容を保存")
                        .frame(maxWidth: .infinity)
                        .tonalPill(enabled: canSave, colorScheme: colorScheme)
                }
                .disabled(!canSave)
                .padding(.top, 8)

                Divider().padding(.vertical, 14)

                HStack {
                    Text("保存した内容")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }

                if store.savedProjects.isEmpty {
                    HStack {
                        Text("まだありません")
                            .font(.system(size: 12))
                            .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                        Spacer()
                    }
                    .padding(.top, 6)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.savedProjects) { project in
                                SavedProjectRow(
                                    project: project,
                                    onLoad: { store.loadProject(project); onDismiss() },
                                    onOverwrite: { store.overwriteProject(id: project.id, name: project.name) },
                                    onDelete: { pendingDelete = project }
                                )
                            }
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxHeight: 220)
                }

                HStack {
                    Spacer()
                    Button("閉じる") { onDismiss() }
                        .foregroundStyle(AppColors.primary(colorScheme))
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.top, 16)
            }
            .padding(24)
            .background(AppColors.cardHigh(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)
            .frame(maxWidth: 420)
        }
        .onAppear { name = nextDefaultName() }
        .alert("上限に達しています", isPresented: $showLimitAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("保存は20件までです。不要なものを削除してください")
        }
        .alert("削除しますか", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button("削除", role: .destructive) {
                // 削除した行が瞬時に消えず、フェードアウトしながら後続の行が詰まるようにする
                // （Android版のLazyColumn+animateItem()と同じ狙い）
                withAnimation {
                    if let id = pendingDelete?.id { store.deleteSavedProject(id: id) }
                }
                pendingDelete = nil
            }
            Button("キャンセル", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("「\(pendingDelete?.name ?? "")」を削除します。元には戻せません。")
        }
    }

    /// 既定の保存名 "M/d"。同名があれば "M/d (1)" のように連番を付ける（Android: defaultSaveName）
    private func nextDefaultName() -> String {
        Formatters.defaultSaveName(existingNames: Set(store.savedProjects.map { $0.name }))
    }
}

private struct SavedProjectRow: View {
    let project: SavedProject
    let onLoad: () -> Void
    let onOverwrite: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                Text("\(project.clipCount)本・\(durationLabel)　\(savedAtLabel)")
                    .font(.system(size: 11))
                    .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColors.error(colorScheme))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
        .background(AppColors.cardHigh(colorScheme).opacity(0.001)) // 当たり判定を全面に広げる
        .background(RoundedRectangle(cornerRadius: 8).fill(AppColors.card(colorScheme)))
        .contentShape(Rectangle())
        .onTapGesture { onLoad() }
        .onLongPressGesture { onOverwrite() }
    }

    private var savedAtLabel: String {
        Formatters.savedAtLabel(msSinceEpoch: project.savedAt)
    }

    private var durationLabel: String {
        Formatters.durationLabel(ms: project.totalMs)
    }
}
