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
    /// 「書き出し」タップ時に、自由入力の内容そのまま（未選択ならnil）で呼ばれる。
    ///
    /// 「空なら撮影日へ戻す」というフォールバックはここでは判断しない。
    /// 焼き込む文言を最終的に決めるのは`ExportManager.resolveTitleText`1箇所だけにしてある
    /// （以前は両方で判定していて、片方だけ前後の空白を落としているというズレがあった）。
    let onConfirm: (_ customTitleText: String?) -> Void

    @Environment(\.colorScheme) var colorScheme
    @State private var customText: String? = nil

    /// 1行ぶんの高さ。入力欄の下限（＝空のときの見た目）に使う。
    /// 中の文字が文字サイズ設定で伸びるので、こちらも一緒に伸ばす
    @ScaledMetric(relativeTo: .body) private var inputLineHeight: CGFloat = 22
    /// 入力欄を伸ばす上限の行数。これを超えたら中でスクロールさせる
    private let inputMaxLines: Int = 4

    private var isCustomSelected: Bool { customText != nil }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { onDismiss() }

            VStack(alignment: .leading, spacing: 0) {
                Text("タイトル作成")
                    .vlogFont(20, weight: .semibold)
                    .padding(.bottom, 20)

                // 日付を選ぶ行。中身はTextだけでフォーカス取得と競合する要素がないので、
                // 行全体にタップ判定を乗せて問題ない。
                HStack(alignment: .center, spacing: 8) {
                    radioIcon(selected: !isCustomSelected)
                    Text(defaultDateText)
                        .font(.vlogCustom(VlogFonts.timeFontName, size: 15))
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { customText = nil }
                // ラジオの丸は見た目だけで、選択中かどうかはVoiceOverに伝わらない。
                // 行をひとつの選択肢としてまとめ、状態をトレイトで示す
                .accessibilityElement(children: .combine)
                .accessibilityLabel("撮影日 \(defaultDateText) をタイトルにする")
                .accessibilityAddTraits(isCustomSelected ? [.isButton] : [.isButton, .isSelected])

                // 自由入力の行。Android版（RadioOptionRow）と違い、行全体にタップ判定を重ねると
                // TextField自身のタップ（フォーカス取得）と競合してしまう。Android版でも選択の
                // 切り替えは実質「入力された瞬間にcustomTextが非nilになる」ことで起きているので、
                // ここではアイコン単体だけをタップ対象にし、あとは入力（Bindingのset）に選択を任せる。
                HStack(alignment: .center, spacing: 8) {
                    radioIcon(selected: isCustomSelected)
                        .onTapGesture {
                            if customText == nil { customText = "" }
                        }
                        .accessibilityElement()
                        .accessibilityLabel("自由に入力したタイトルにする")
                        .accessibilityAddTraits(isCustomSelected ? [.isButton, .isSelected] : [.isButton])
                        .accessibilityAction { if customText == nil { customText = "" } }

                    ZStack(alignment: .topLeading) {
                        if (customText ?? "").isEmpty {
                            Text("タイトルを入力")
                                .font(.vlogCustom(VlogFonts.timeFontName, size: 15))
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
                            textColor: colorScheme == .dark ? .white : .black,
                            minHeight: inputLineHeight,
                            maxHeight: inputLineHeight * CGFloat(inputMaxLines)
                        )
                        // ひとこと欄のUITextViewと区別してUIテストから掴めるようにする
                        // （MyVlogAppUITests/ExportUITests.swift）
                        .accessibilityIdentifier("titleTextField")
                        // 枠しかない入力欄なので、何を入れる欄なのかを自分で名乗る
                        .accessibilityLabel("タイトル")
                    }
                    // 高さはGrowingTextViewが内容に合わせて返す（1行ぶん〜inputMaxLines行ぶん）。
                    // 以前は22ptで固定していたため、書き出し側（ExportWorker+TitleCard/
                    // renderTitleFrame）が複数行のタイトルに対応しているのに、
                    // 入力欄では2行目以降が見えないという食い違いがあった
                    .frame(minHeight: inputLineHeight, alignment: .topLeading)
                    .padding(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppColors.outline(colorScheme), lineWidth: 1)
                    )
                }
                .padding(.vertical, 8)

                HStack {
                    Spacer()
                    Button("キャンセル") { onDismiss() }
                        .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                        .vlogFont(14, weight: .semibold)
                        .padding(.trailing, 16)
                    // 入力内容はそのまま渡す。空/空白だけのときに撮影日へ戻す判断は
                    // ExportManager.resolveTitleTextが受け持つ（判定を二重に持たない）
                    Button("書き出し") { onConfirm(customText) }
                    .foregroundStyle(AppColors.primary(colorScheme))
                    .vlogFont(14, weight: .semibold)
                    // 操作バーの「書き出し」と同じラベルなので、テストから区別できるよう識別子を付ける
                    // （MyVlogAppUITests/ExportUITests.swift）
                    .accessibilityIdentifier("confirmExport")
                }
                .padding(.top, 20)
            }
            .padding(24)
            .background(AppColors.cardHigh(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 24)
            .frame(maxWidth: 420)
            // ZStackで重ねているだけなので、これが無いとVoiceOverが後ろの編集画面まで
            // 読み上げてしまう（SavedProjectsViewと同じ理由）
            .accessibilityAddTraits(.isModal)
        }
    }

    private func radioIcon(selected: Bool) -> some View {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
            .foregroundStyle(selected ? AppColors.primary(colorScheme) : AppColors.onSurfaceVariant(colorScheme))
    }
}

/// TitleCreationDialogView専用の入力欄。TextInputView.swiftのNativeTextViewと同じく、
/// SwiftUI標準のTextFieldがこの環境で不安定（入力内容が保持されない等）なのを避けて
/// UITextViewに直結する。
///
/// 名前のとおり内容に合わせて高さが伸びる（`sizeThatFits`でSwiftUIへ高さを返す）。
/// 書き出し側（ExportWorker+TitleCard.createTitleCard / renderTitleFrame）が複数行の
/// タイトルに対応しているので、入力側でも2行目以降が見えるようにしてある。
/// `maxHeight`を超えたぶんは中でスクロールさせる（ダイアログが画面いっぱいに
/// 伸び続けないように）。
private struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    let fontName: String
    let fontSize: CGFloat
    let textColor: UIColor
    /// 空のときでも確保する高さ（1行ぶん）
    let minHeight: CGFloat
    /// これ以上は伸ばさず、中でスクロールさせる高さ
    let maxHeight: CGFloat

    /// 内蔵フォントを、端末の文字サイズ設定に合わせて伸ばしたもの。
    /// 見出しやラベル（SwiftUI側の`vlogFont`/`vlogCustom`）と歩調を合わせる。
    /// 名前で引けなかった場合はシステムフォントへ落とす
    static func scaledFont(name: String, size: CGFloat) -> UIFont {
        let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = Self.scaledFont(name: fontName, size: fontSize)
        tv.adjustsFontForContentSizeCategory = true
        tv.textColor = textColor
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.text = text
        // 内容に合わせて高さを決めるのはこちら（sizeThatFits）なので、
        // UITextView自身が縦に潰れたり引き伸ばされたりしないようにする
        tv.setContentCompressionResistancePriority(.required, for: .vertical)
        tv.setContentHuggingPriority(.required, for: .vertical)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        uiView.font = Self.scaledFont(name: fontName, size: fontSize)
        uiView.textColor = textColor
        // 上限まで伸びきったらスクロールへ切り替える。切り替えないと、
        // 上限を超えて打った部分と入力カーソルが枠の外に出て見えなくなる
        uiView.isScrollEnabled = contentHeight(of: uiView, width: uiView.bounds.width) > maxHeight
    }

    /// SwiftUIへ返す高さ。内容の高さを minHeight…maxHeight の範囲に収める
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return nil }
        let height = min(max(contentHeight(of: uiView, width: width), minHeight), maxHeight)
        return CGSize(width: width, height: height)
    }

    private func contentHeight(of textView: UITextView, width: CGFloat) -> CGFloat {
        guard width > 0 else { return minHeight }
        return textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
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
