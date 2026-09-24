import SwiftUI

/// 「編集内容の保存」ダイアログ。Android版SaveLoadDialogと同じ、中央カード＋暗幕オーバーレイで
/// 保存・上書き・読み出し・削除をまとめる。
struct SavedProjectsView: View {
    @Environment(VlogStore.self) private var store
    @Environment(\.colorScheme) var colorScheme
    let onDismiss: () -> Void

    @State private var name: String = ""
    @State private var pendingDelete: SavedProject? = nil
    /// 上書きの確認待ち。上書きも「もとに戻す」では戻せない（戻せるのはタイムラインの編集だけで、
    /// 上書きされた保存の中身は失われる）ので、長押しでの誤操作を防ぐため確認を挟む（Android: SaveLoadDialog）
    @State private var pendingOverwrite: SavedProject? = nil
    @State private var showLicense: Bool = false

    /// 保存も上書きも、タイムラインが空のとき・動画の読み込み中はさせない
    private var canSave: Bool { !store.clips.isEmpty && !store.isImporting }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                Image(systemName: "doc.fill")
                    .vlogFont(28)
                    .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                    .padding(.top, 24)

                Text("編集内容の保存")
                    .vlogFont(20, weight: .semibold)
                    .padding(.top, 12)
                    .padding(.bottom, 20)

                VStack(alignment: .leading, spacing: 4) {
                    Text("保存名")
                        .vlogFont(11)
                        .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                    TextField("", text: $name)
                        .textFieldStyle(.plain)
                        .padding(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppColors.outline(colorScheme), lineWidth: 1)
                        )
                        .disabled(!canSave)
                }

                Button {
                    // 保存したら閉じる。開いたままだと続けて押せてしまい、同じ内容が
                    // 「名前」「名前 (1)」の2件になる（Android: SaveLoadDialog）。
                    // 保存できたか（付いた名前・上限で断ったこと）はstoreがトーストで知らせる。
                    // 名前が空なら保存日時を名前にする判断もstore側
                    store.saveCurrentProject(name: name)
                    onDismiss()
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
                        .vlogFont(14, weight: .semibold)
                    Spacer()
                }

                if store.savedProjects.isEmpty {
                    HStack {
                        Text("まだありません")
                            .vlogFont(12)
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
                                    // 保存できないとき（タイムラインが空など）は長押しも受け付けない。
                                    // 受け付けると、確認まで進んでから断ることになる
                                    onOverwrite: canSave ? { pendingOverwrite = project } : nil,
                                    onDelete: { pendingDelete = project }
                                )
                            }
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxHeight: 220)
                }

                HStack {
                    // ライセンスの入口はここに置く。メイン画面のボタン列に足すと「動画を追加」と
                    // 「書き出し」の幅が削られるため、ふだん開く補助的なダイアログの下端に寄せた（Android と同じ）
                    Button("ライセンス") { showLicense = true }
                        .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                        .vlogFont(14, weight: .semibold)
                    Spacer()
                    Button("閉じる") { onDismiss() }
                        .foregroundStyle(AppColors.primary(colorScheme))
                        .vlogFont(14, weight: .semibold)
                }
                .padding(.top, 16)
            }
            .padding(24)
            .background(AppColors.cardHigh(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)
            .frame(maxWidth: 420)
            // ZStackで重ねているだけなので、これが無いとVoiceOverが後ろの編集画面まで
            // 読み上げてしまい、閉じたつもりのないダイアログの外を触れてしまう
            .accessibilityAddTraits(.isModal)
        }
        .onAppear { name = nextDefaultName() }
        .overlay {
            if showLicense {
                LicenseView(onDismiss: { showLicense = false })
                    .transition(.opacity)
            }
        }
        .animation(.default, value: showLicense)
        .alert("上書きしますか", isPresented: Binding(
            get: { pendingOverwrite != nil },
            set: { if !$0 { pendingOverwrite = nil } }
        )) {
            Button("上書き", role: .destructive) {
                if let target = pendingOverwrite {
                    store.overwriteProject(id: target.id, name: target.name)
                }
                pendingOverwrite = nil
            }
            Button("キャンセル", role: .cancel) { pendingOverwrite = nil }
        } message: {
            Text("「\(pendingOverwrite?.name ?? "")」を、いまの編集内容で上書きします。元の保存内容には戻せません。")
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
    /// いま上書きできないときはnil（長押しを受け付けず、読み上げのアクションにも出さない）
    let onOverwrite: (() -> Void)?
    let onDelete: () -> Void

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .vlogFont(12, weight: .bold)
                    .lineLimit(1)
                Text("\(project.clipCount)本・\(durationLabel)　\(savedAtLabel)")
                    .vlogFont(11)
                    .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
            }
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .vlogFont(14)
                    .foregroundStyle(AppColors.error(colorScheme))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("「\(project.name)」を削除")
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
        .background(AppColors.cardHigh(colorScheme).opacity(0.001)) // 当たり判定を全面に広げる
        .background(RoundedRectangle(cornerRadius: 8).fill(AppColors.card(colorScheme)))
        .contentShape(Rectangle())
        .onTapGesture { onLoad() }
        .onLongPressGesture { onOverwrite?() }
        // 読み出し（タップ）と上書き（長押し）はジェスチャーでしか用意しておらず、
        // VoiceOverからはどちらも実行できなかった。行をひとつの項目にまとめ、
        // 既定の操作を「読み出し」、上書きと削除をカスタム操作として出す
        // （削除は行内のボタンにもあるが、行に入らず操作できるほうが早い）
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(project.name)。\(project.clipCount)本、\(durationLabel)、\(savedAtLabel)に保存")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("読み出すと、いまの編集内容を置き換えます")
        .accessibilityAction { onLoad() }
        .modifier(OverwriteAction(onOverwrite: onOverwrite))
        .accessibilityAction(named: "削除") { onDelete() }
    }

    private var savedAtLabel: String {
        Formatters.savedAtLabel(msSinceEpoch: project.savedAt)
    }

    private var durationLabel: String {
        Formatters.durationLabel(ms: project.totalMs)
    }
}

/// 上書きのアクションを、上書きできるときだけVoiceOverに出す
private struct OverwriteAction: ViewModifier {
    let onOverwrite: (() -> Void)?

    func body(content: Content) -> some View {
        if let onOverwrite {
            content.accessibilityAction(named: "この内容で上書き", onOverwrite)
        } else {
            content
        }
    }
}
