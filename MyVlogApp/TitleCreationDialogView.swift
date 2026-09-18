import SwiftUI
import UIKit

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

                // 日付を選ぶ行。中身はTextだけでフォーカス取得と競合する要素がないので、
                // 行全体にタップ判定を乗せて問題ない。
                HStack(alignment: .center, spacing: 8) {
                    radioIcon(selected: !isCustomSelected)
                    Text(defaultDateText)
                        .font(.custom(VlogFonts.timeFontName, size: 15))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { customText = nil }

                // 自由入力の行。Android版（RadioOptionRow）と違い、行全体にタップ判定を重ねると
                // TextField自身のタップ（フォーカス取得）と競合してしまう。Android版でも選択の
                // 切り替えは実質「入力された瞬間にcustomTextが非nilになる」ことで起きているので、
                // ここではアイコン単体だけをタップ対象にし、あとは入力（Bindingのset）に選択を任せる。
                HStack(alignment: .center, spacing: 8) {
                    radioIcon(selected: isCustomSelected)
                        .onTapGesture {
                            if customText == nil { customText = "" }
                        }

                    ZStack(alignment: .topLeading) {
                        if (customText ?? "").isEmpty {
                            Text("タイトルを入力")
                                .font(.custom(VlogFonts.timeFontName, size: 15))
                                .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                                .allowsHitTesting(false)
                        }
                        // SwiftUI標準のTextField(axis: .vertical)がこの環境（iOS 27 SDK）で
                        // 入力内容を保持できない（打っても消える）ことが実機確認で分かったため、
                        // 既存のNativeTextView（TextInputView.swift）と同じくUITextViewに直結する。
                        GrowingTextView(
                            text: Binding(get: { customText ?? "" }, set: { customText = $0 }),
                            fontName: VlogFonts.timeFontName,
                            fontSize: 15,
                            textColor: colorScheme == .dark ? .white : .black
                        )
                    }
                    .frame(height: 22)
                    .padding(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppColors.outlineVariant(colorScheme), lineWidth: 1)
                    )
                }
                .padding(.vertical, 8)

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

    private func radioIcon(selected: Bool) -> some View {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(selected ? AppColors.primary(colorScheme) : AppColors.onSurfaceVariant(colorScheme))
    }
}

/// TitleCreationDialogView専用の1行入力欄。TextInputView.swiftのNativeTextViewと同じく、
/// SwiftUI標準のTextFieldがこの環境で不安定（入力内容が保持されない等）なのを避けて
/// UITextViewに直結する。
private struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    let fontName: String
    let fontSize: CGFloat
    let textColor: UIColor

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont(name: fontName, size: fontSize)
        tv.textColor = textColor
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.text = text
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        uiView.font = UIFont(name: fontName, size: fontSize)
        uiView.textColor = textColor
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView
        init(_ parent: GrowingTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}
