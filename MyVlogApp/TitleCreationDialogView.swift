import SwiftUI

/// 書き出しボタン（タップ＝タイトルあり）を押した直後に出す、タイトルカード文言の選択ダイアログ。
/// Android版TitleCreationDialogと同じ、中央カード＋暗幕オーバーレイで
/// 「先頭クリップの撮影日（既定で選択済み）」／「自由入力」の2択をまとめる。
///
/// 選択状態は`customText`1つだけで表す（nil＝日付を選択中、非nil＝自由入力を選択中）。
/// 自由入力欄への入力自体が選択を兼ねるので、別建てのラジオ選択肢の状態は持たない
/// （Android版TitleCreationDialogと同じ設計）。
struct TitleCreationDialogView: View {
    let defaultDateText: String
    let onDismiss: () -> Void
    /// 「書き出し」タップ時に呼ばれる。自由入力が空/未選択ならdefaultDateTextを渡す
    /// （フォールバックの判定はここ1箇所だけで行う）。
    let onConfirm: (_ titleText: String) -> Void

    @Environment(\.colorScheme) var colorScheme
    @State private var customText: String? = nil

    private var isCustomSelected: Bool { customText != nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("タイトル作成")
                    .font(.system(size: 20, weight: .semibold))
                    .padding(.bottom, 20)

                radioRow(selected: !isCustomSelected, onSelect: { customText = nil }) {
                    Text(defaultDateText)
                        .font(.custom(VlogFonts.timeFontName, size: 15))
                }

                radioRow(
                    selected: isCustomSelected,
                    onSelect: { if !isCustomSelected { customText = "" } },
                    alignTop: true
                ) {
                    TextField(
                        "タイトルを入力",
                        text: Binding(get: { customText ?? "" }, set: { customText = $0 }),
                        axis: .vertical
                    )
                    .font(.custom(VlogFonts.timeFontName, size: 15))
                    .textFieldStyle(.plain)
                    .padding(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppColors.outlineVariant(colorScheme), lineWidth: 1)
                    )
                }

                HStack {
                    Spacer()
                    Button("キャンセル") { onDismiss() }
                        .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.trailing, 16)
                    Button("書き出し") {
                        let trimmed = customText?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let customText, trimmed?.isEmpty == false {
                            onConfirm(customText)
                        } else {
                            onConfirm(defaultDateText)
                        }
                    }
                    .foregroundStyle(AppColors.primary(colorScheme))
                    .font(.system(size: 14, weight: .semibold))
                }
                .padding(.top, 20)
            }
            .padding(24)
            .background(AppColors.cardHigh(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)
            .frame(maxWidth: 420)
        }
    }

    /// ラジオボタン1個＋その選択肢の中身、という行の共通レイアウト
    @ViewBuilder
    private func radioRow<Content: View>(
        selected: Bool,
        onSelect: @escaping () -> Void,
        alignTop: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignTop ? .top : .center, spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? AppColors.primary(colorScheme) : AppColors.onSurfaceVariant(colorScheme))
            content()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
