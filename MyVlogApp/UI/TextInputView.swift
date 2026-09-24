import SwiftUI
import UIKit

struct TextInputView: View {
    @Environment(VlogStore.self) private var store
    @Environment(VideoPlayerManager.self) private var playerManager
    @Environment(ExportManager.self) private var exportManager
    @Environment(\.colorScheme) var colorScheme

    @State private var text:         String = ""
    @State private var segmentIndex: Int    = 0
    @State private var isEditing:    Bool   = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                // Segment indicator（Android: EditorPane、常に「ひとこと」見出し＋区間バッジ）
                HStack(spacing: 6) {
                    Text("ひとこと")
                        .vlogFont(14, weight: .semibold)
                        .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                    if let clip = store.selectedClip, clip.texts.count > 1 {
                        Text("\(segmentIndex + 1)")
                            .vlogFont(9, weight: .bold)
                            .foregroundStyle(AppColors.onSplitLine(colorScheme))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(AppColors.splitLine(colorScheme)))
                        Text("／\(clip.texts.count) 区間目を編集中")
                            .vlogFont(11)
                            .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)

                // EagerFirstResponderTextView を使うことで、SwiftUIのジェスチャー配送と
                // UIKitのfirst responder化のタイムラグによる「1回目タップでキーボードが
                // 開かない」問題を根本的に解消する。
                NativeTextView(
                    text: $text,
                    // クリップが無いときと書き出し中は打たせない（Android: EditorPane の enabled）。
                    // 以前はクリップが無くても打てて、打った文字はどこにも入らずに残っていた
                    isEnabled: store.selectedClip != nil && !exportManager.isExporting,
                    // 未入力のときだけ「ひとこと」をグレーで案内表示する。見た目だけで、
                    // 実際の値は空文字のまま（プレビュー・書き出しには何も焼き込まれない）
                    placeholder: TextSegment.defaultText,
                    onBeginEditing: {
                        isEditing = true
                        playerManager.pause()
                    },
                    onEndEditing: {
                        isEditing = false
                    },
                    onChange: { newText in
                        store.updateText(newText, segmentIndex: segmentIndex)
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isEditing ? AppColors.primary : Color.clear, lineWidth: 1.5)
                )
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppColors.card(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        // 再生位置の監視は葉へ逃がす。ここで .onChange(of: playerManager.currentTimeMs) と
        // 書くと、このbodyが再生位置を読んだことになり、再生中ずっと毎秒30回
        // 作り直される（UITextViewのupdateUIViewも毎回走る）
        .overlay { PlaybackPositionObserver { _ in if !isEditing { syncSegment() } } }
        // 選択中のクリップが「別のもの」に変わったときに読み直す。indexではなくidで見るのは
        // ContentViewと同じ理由（indexは値が変わらないまま中身だけ入れ替わることがある）
        .onChange(of: store.selectedClip?.id) { syncText() }
        // 外からひとことが書き換わったとき（もとに戻す/やり直す・分割・区切りの解除）に追従する。
        //
        // 以前はclips配列全体をonChangeの対象にしていた。ひとことを1文字打つたびに
        // 全クリップ（最大100本、それぞれtexts配列を持つ）の==比較が走るうえ、
        // このViewのbodyまで毎打鍵で作り直されていた（UITextViewのupdateUIViewを含む）。
        // 必要なのは選択中クリップのtextsだけなので、そこへ絞る
        // （ContentView.swiftが同じ理由でisEmpty/isMutedへ絞っているのと同じ方針）。
        .onChange(of: store.selectedClip?.texts) {
            if !isEditing { syncText() }
        }
        .onAppear { syncText() }
        // 打っている間は再生させない。入力を始めたら止める（onBeginEditing）だけでは、
        // キーボードを出したままプレビューをタップすると再生が始まり、プレビューには
        // 別の区間の文字が流れているのに入力欄は編集を始めた区間のまま、という
        // 食い違った状態になる。再生が始まったら入力欄から抜ける（Android: EditorPane）
        .onChange(of: playerManager.isPlaying) { _, playing in
            guard playing, isEditing else { return }
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
            )
        }
    }

    private func syncText() {
        guard !isEditing else { return }
        guard let clip = store.selectedClip else { text = ""; return }
        let pos = playerManager.currentTimeMs
        segmentIndex = clip.textIndexAt(positionMs: pos)
        if clip.texts.indices.contains(segmentIndex) {
            let newText = clip.texts[segmentIndex].text
            if text != newText { text = newText }
        }
    }

    private func syncSegment() {
        guard !isEditing else { return }
        guard let clip = store.selectedClip else { return }
        let pos     = playerManager.currentTimeMs
        let newIdx  = clip.textIndexAt(positionMs: pos)
        if newIdx != segmentIndex {
            segmentIndex = newIdx
            if clip.texts.indices.contains(newIdx) {
                let newText  = clip.texts[newIdx].text
                if text != newText { text = newText }
            }
        }
    }
}

// MARK: - Native UITextView Representable

struct NativeTextView: UIViewRepresentable {
    @Binding var text: String
    var isEnabled: Bool = true
    var placeholder: String
    var onBeginEditing: (() -> Void)? = nil
    var onEndEditing: (() -> Void)? = nil
    var onChange: ((String) -> Void)? = nil

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeTextView
        var placeholderLabel: UILabel?

        init(_ parent: NativeTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            // タップした瞬間（打ち始める前）に案内文字を消す。空欄のまま残すと、
            // カーソルと「ひとこと」が重なって、すでに入力済みのように見える
            // （Android: EditorPaneのplaceholderもフォーカス中は出さない）
            placeholderLabel?.isHidden = true
            parent.onBeginEditing?()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel?.isHidden = textView.isFirstResponder || !textView.text.isEmpty
            parent.onChange?(textView.text)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            placeholderLabel?.isHidden = !textView.text.isEmpty
            parent.onEndEditing?()
        }
    }

    /// 設計上15ptの本文を、端末の文字サイズ設定に合わせて伸ばしたもの。
    /// SwiftUI側の`vlogFont`（VlogTypography.swift）とそろえてある
    private static var scaledBodyFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EagerFirstResponderTextView {
        let tv = EagerFirstResponderTextView()
        tv.delegate = context.coordinator
        // UITextViewはSwiftUIのDynamic Typeが効かないので、自分で追従させる。
        // adjustsFontForContentSizeCategoryを立てておくと、設定を変えたときに
        // アプリを開き直さなくても反映される
        tv.font = Self.scaledBodyFont
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.textColor = UIColor.label
        tv.textAlignment = .center
        tv.text = text
        tv.isScrollEnabled = true
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)

        // 幅はUIKitがキーボードの幅へ合わせてくれるので、こちらで決めるのは高さだけでよい
        // （sizeToFitが標準の44ptを入れ、flexibleWidthで幅の変化に追従する）。
        // 以前はUIScreen.main.bounds.widthを初期幅に入れていたが、マルチウィンドウや
        // Stage Managerではアプリの幅と一致せず、正しい値ではなかった。
        let toolbar = UIToolbar()
        toolbar.autoresizingMask = .flexibleWidth
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "閉じる", style: .done, target: tv,
                                   action: #selector(UIResponder.resignFirstResponder))
        done.tintColor = UIColor(AppColors.primary)
        toolbar.items = [flex, done]
        toolbar.sizeToFit()
        // UIテストからキーボードを閉じる手段として掴めるようにする（MyVlogAppUITests.swift）
        done.accessibilityIdentifier = "keyboardDone"
        tv.inputAccessoryView = toolbar

        let pl = UILabel()
        pl.text = placeholder
        pl.font = Self.scaledBodyFont
        pl.adjustsFontForContentSizeCategory = true
        pl.textColor = UIColor.placeholderText
        pl.textAlignment = .center
        pl.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(pl)
        context.coordinator.placeholderLabel = pl

        NSLayoutConstraint.activate([
            pl.leadingAnchor.constraint(greaterThanOrEqualTo: tv.leadingAnchor, constant: 10),
            pl.trailingAnchor.constraint(lessThanOrEqualTo: tv.trailingAnchor, constant: -10),
            pl.centerXAnchor.constraint(equalTo: tv.centerXAnchor),
            pl.topAnchor.constraint(equalTo: tv.topAnchor, constant: 8)
        ])
        pl.isHidden = !text.isEmpty

        return tv
    }

    func updateUIView(_ uiView: EagerFirstResponderTextView, context: Context) {
        context.coordinator.parent = self
        if uiView.isEditable != isEnabled {
            // 打っている途中で書き出しが始まったら、入力欄から抜ける
            if !isEnabled, uiView.isFirstResponder { uiView.resignFirstResponder() }
            uiView.isEditable   = isEnabled
            uiView.isSelectable = isEnabled
            uiView.alpha        = isEnabled ? 1 : 0.5
        }
        if uiView.text != text {
            uiView.text = text
            context.coordinator.placeholderLabel?.isHidden = uiView.isFirstResponder || !text.isEmpty
        }
        context.coordinator.placeholderLabel?.text = placeholder
    }
}

// MARK: - EagerFirstResponderTextView

/// touchesBeganでeagerly becomeFirstResponder()を呼ぶUITextViewサブクラス。
/// SwiftUIのジェスチャー認識とUIKitのfirst responder化の間にあるタイムラグが
/// 実機（特にiPad）で「1回目タップでキーボードが開かない」症状を引き起こすが、
/// touchesBegan時点では既にhitTestがこのビューを選択しているため、ここで
/// becomeFirstResponder()を呼べば確実かつ即座にキーボードが表示される。
final class EagerFirstResponderTextView: UITextView {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // 打たせないとき（クリップが無い・書き出し中）はキーボードを出さない
        if isEditable, !isFirstResponder {
            _ = becomeFirstResponder()
        }
    }
}
