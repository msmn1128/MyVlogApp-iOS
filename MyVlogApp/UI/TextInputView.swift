import SwiftUI
import UIKit.UIGestureRecognizerSubclass
import UIKit

struct TextInputView: View {
    @Environment(VlogStore.self) private var store
    @Environment(VideoPlayerManager.self) private var playerManager
    @Environment(ExportManager.self) private var exportManager
    @Environment(\.colorScheme) var colorScheme

    /// 見出し（「ひとこと」と区間の番号）を出すか。縦に短い画面でキーボードを出している間は畳む（ContentView）
    var showHeader: Bool = true

    @State private var text:         String = ""
    @State private var segmentIndex: Int    = 0
    @State private var isEditing:    Bool   = false
    /// 入力欄を最後に合わせたクリップ。クリップが切り替わると、ひとことの中身の監視（texts）も同時に
    /// 呼ばれる。そちらは再生位置（まだ前のクリップのまま）で合わせてしまうので、切り替えの処理
    /// （selectedClip?.id の監視）に任せて何もしない
    @State private var syncedClipId: UUID?   = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                if showHeader {
                    // Segment indicator（Android: EditorPane、常に「ひとこと」見出し＋区間バッジ）
                    HStack(spacing: 6) {
                        Text("ひとこと")
                            .vlogFont(14, weight: .semibold)
                            .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                            // 読み上げの見出しにする（見出しで飛べる。Android f173f12）
                            .accessibilityAddTraits(.isHeader)
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
                }

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
        // ContentViewと同じ理由（indexは値が変わらないまま中身だけ入れ替わることがある）。
        //
        // 打っている最中（キーボードを出したまま別のタイルを押した）でも読み直す。以前は打っている間は
        // 読み直さず、下のtextsの監視が「文字が食い違ったら合わせ直す」だけだったため、編集中の区間の
        // 文字が2本で同じ（どちらも未入力など）だと、前のクリップの区間の番号のまま残り、打った文字が
        // 新しいクリップの再生位置と違う区間（前のクリップで2区間目なら、新しいクリップでも2区間目）に入っていた
        //
        // 区間は新しいクリップの頭（トリム開始）で決める。再生位置は、読み込みが終わって頭を出すまで
        // 前のクリップのままなので、それで決めると別の区間を選んでしまう
        .onChange(of: store.selectedClip?.id) { syncText(force: true, atMs: store.selectedClip?.startMs) }
        // 外からひとことが書き換わったとき（もとに戻す/やり直す・分割・区切りの解除）に追従する。
        //
        // 以前はclips配列全体をonChangeの対象にしていた。ひとことを1文字打つたびに
        // 全クリップ（最大100本、それぞれtexts配列を持つ）の==比較が走るうえ、
        // このViewのbodyまで毎打鍵で作り直されていた（UITextViewのupdateUIViewを含む）。
        // 必要なのは選択中クリップのtextsだけなので、そこへ絞る
        // （ContentView.swiftが同じ理由でisEmpty/isMutedへ絞っているのと同じ方針）。
        .onChange(of: store.selectedClip?.texts) {
            guard store.selectedClip?.id == syncedClipId else { return }
            if !isEditing { syncText(); return }
            // 打っている最中でも、外から変わったとき（キーボードを出したままの「もとに戻す」「やり直す」）は
            // 入力欄を合わせ直す。打った文字はその場で保存側へ流しているので、保存側と入力欄が
            // 食い違うのは外から変わったときだけ。合わせないと入力欄に戻す前の文字が残り、次の1文字で
            // それが丸ごと書き戻されて「もとに戻す」が打ち消されていた。区切りが減って編集中の区間が
            // 無くなった場合は、打った文字がどこにも入らず捨てられていた（Android: EditorPane）
            guard let clip = store.selectedClip else { return }
            if !clip.texts.indices.contains(segmentIndex) || clip.texts[segmentIndex].text != text {
                syncText(force: true)
            }
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

    /// - Parameters:
    ///   - force: 打っている最中でも合わせ直す（外から変わったとき）
    ///   - atMs: どの位置の区間に合わせるか。省くといまの再生位置
    private func syncText(force: Bool = false, atMs: Int64? = nil) {
        guard force || !isEditing else { return }
        syncedClipId = store.selectedClip?.id
        guard let clip = store.selectedClip else { text = ""; return }
        let pos = atMs ?? playerManager.currentTimeMs
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
        // 何の欄かを読み上げに伝える。見出し（showHeader）を出さない配置もあり、名前が無いと
        // 未入力のときは「テキストフィールド」としか読まれなかった。iOSでは名前を付けても、打った文字は
        // 名前のあとに値として読まれる（Androidは名前を付けると文字の代わりに読まれるので、見出しで伝えている）
        tv.accessibilityLabel = TextSegment.defaultText

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
    /// いまのタップで、カーソルを文字の終わりへ置き直すか（理由は handleTap）
    private var moveCaretToEndAfterTap = false
    /// 下の tap のdelegate。認識器はdelegateを弱く持つので、ここで持っておく
    private let simultaneousDelegate = SimultaneousGestureDelegate()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        // 指を置いた瞬間に見る。指を離すころには入力がもう始まっていて、入力を始めるタップだったかが分からない
        let touchDown = TouchDownRecognizer { [weak self] point in
            guard let self else { return }
            // 入力を始めるタップか、入力中に文字（最後の行）より下をタップしたか
            self.moveCaretToEndAfterTap = !self.isFirstResponder
                || point.y > self.caretRect(for: self.endOfDocument).maxY
        }
        addGestureRecognizer(touchDown)
        // タップが終わったら（UIKitがカーソルを置いたあと）置き直す。UITextView自身のタップの処理を
        // 妨げないよう、同時に認識させ、タッチも横取りしない
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        // delegateをこのビュー自身にしない。UIScrollViewは自分のパン認識器のdelegateを自分にしているので、
        // ここで同時認識をtrueにすると、入力欄のスクロールまで外側の画面と一緒に動くようになる
        tap.delegate = simultaneousDelegate
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    /// 入力を始めるタップと、入力中に文字の下の空いている所をタップしたときは、カーソルを文字の終わりに置く。
    ///
    /// 中央ぞろえのUITextViewは、入力を始めるタップでカーソルを先頭に置くことがある（UIテストで確認。
    /// 文字の下をタップしても先頭になる）。そのため2回目からは、打った文字が頭に入っていた
    /// （「A1」のあとにタップして打つと「B2A1」）。ひとことは短い文言で、書き足すことが多いので終わりに置く。
    /// 途中を直したいときは、入力が始まってからもう一度タップすれば、その位置に置ける。
    ///
    /// どちらのタップかは、指を置いた瞬間に見る（TouchDownRecognizer）。置き直すのは、UIKitがタップを
    /// 処理してカーソルを置いたあと（次の周回）。touchesBegan/Endedは使えない（タップはUITextView自身の
    /// 文字入力の仕組みが受け取り、ここまで届かない。UIテストで確認）
    @objc private func handleTap() {
        guard moveCaretToEndAfterTap else { return }
        moveCaretToEndAfterTap = false
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isFirstResponder, self.selectedTextRange?.isEmpty ?? true else { return }
            let end = self.endOfDocument
            self.selectedTextRange = self.textRange(from: end, to: end)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        // 打たせないとき（クリップが無い・書き出し中）はキーボードを出さない
        if isEditable, !isFirstResponder {
            _ = becomeFirstResponder()
        }
    }
}

/// 指を置いた瞬間の位置を知らせるだけの認識器。知らせたらすぐ失敗して、ほかの認識器を妨げない
private final class TouchDownRecognizer: UIGestureRecognizer {
    private let onTouchDown: (CGPoint) -> Void

    init(onTouchDown: @escaping (CGPoint) -> Void) {
        self.onTouchDown = onTouchDown
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view { onTouchDown(touch.location(in: view)) }
        state = .failed
    }
}

/// ほかの認識器と同時に認識させるだけのdelegate（EagerFirstResponderTextView のカーソル置き直しのタップ用）
private final class SimultaneousGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
}
