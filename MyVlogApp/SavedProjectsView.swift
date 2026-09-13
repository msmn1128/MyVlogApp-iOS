import SwiftUI

struct SavedProjectsView: View {
    @EnvironmentObject var store: VlogStore
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    @State private var saveName:       String = ""
    @State private var showSaveError:  Bool   = false
    @State private var confirmDeleteID: Int64? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // ── Save current ──
                VStack(alignment: .leading, spacing: 8) {
                    Text("現在の編集内容を保存")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField("プロジェクト名", text: $saveName)
                            .textFieldStyle(.roundedBorder)
                        Button("保存") {
                            if store.saveCurrentProject(name: saveName.isEmpty ? "無題" : saveName) {
                                saveName = ""
                            } else {
                                showSaveError = true
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppColors.primary)
                        .disabled(store.clips.isEmpty)
                    }
                }
                .padding()
                .background(AppColors.card(colorScheme))

                Divider()

                // ── Saved list ──
                if store.savedProjects.isEmpty {
                    ContentUnavailableView(
                        "保存されたプロジェクトなし",
                        systemImage: "tray",
                        description: Text("上のフォームで現在の編集を保存できます")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.savedProjects) { project in
                            ProjectRow(project: project)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.loadProject(project)
                                    dismiss()
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        confirmDeleteID = project.id
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("保存プロジェクト")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .alert("上限に達しています", isPresented: $showSaveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("保存できるプロジェクトは最大20件です。古いものを削除してください。")
            }
            .alert("削除の確認", isPresented: Binding(
                get: { confirmDeleteID != nil },
                set: { if !$0 { confirmDeleteID = nil } }
            )) {
                Button("削除", role: .destructive) {
                    if let id = confirmDeleteID { store.deleteSavedProject(id: id) }
                    confirmDeleteID = nil
                }
                Button("キャンセル", role: .cancel) { confirmDeleteID = nil }
            } message: {
                Text("このプロジェクトを削除します。この操作は取り消せません。")
            }
        }
    }
}

private struct ProjectRow: View {
    let project: SavedProject
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(project.name)
                .font(.headline)
            HStack {
                Text(dateLabel)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(project.clipCount)クリップ · \(durationLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var dateLabel: String {
        let date = Date(timeIntervalSince1970: Double(project.savedAt) / 1000)
        let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: date)
    }

    private var durationLabel: String {
        let s = project.totalMs / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
