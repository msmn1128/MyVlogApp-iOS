import SwiftUI
import UIKit

struct TextInputView: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                    if let clip = store.selectedClip, clip.texts.count > 1 {
                        Text("\(segmentIndex + 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(AppColors.onSplitLine(colorScheme))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(AppColors.splitLine(colorScheme)))
                        Text("／\(clip.texts.count) 区間目を編集中")
                            .font(.system(size: 11))
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
                    placeholder: store.selectedClip == nil ? "「動画を追加」から動画を選んでください" : "テロップを入力...",
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
        .onChange(of: store.selectedIndex) { syncText() }
        .onChange(of: playerManager.currentTimeMs) {
            if !isEditing { syncSegment() }
        }
        .onChange(of: store.clips) {
            if !isEditing { syncText() }
        }
        .onAppear { syncText() }
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
            placeholderLabel?.isHidden = !textView.text.isEmpty
            parent.onBeginEditing?()
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            placeholderLabel?.isHidden = !textView.text.isEmpty
            parent.onChange?(textView.text)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            placeholderLabel?.isHidden = !textView.text.isEmpty
            parent.onEndEditing?()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> EagerFirstResponderTextView {
        let tv = EagerFirstResponderTextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.systemFont(ofSize: 15)
        tv.backgroundColor = .clear
        tv.textColor = UIColor.label
        tv.text = text
        tv.isScrollEnabled = true
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)

        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "閉じる", style: .done, target: tv,
                                   action: #selector(UIResponder.resignFirstResponder))
        done.tintColor = UIColor(AppColors.primary)
        toolbar.items = [flex, done]
        toolbar.sizeToFit()
        tv.inputAccessoryView = toolbar

        let pl = UILabel()
        pl.text = placeholder
        pl.font = UIFont.systemFont(ofSize: 15)
        pl.textColor = UIColor.placeholderText
        pl.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(pl)
        context.coordinator.placeholderLabel = pl

        NSLayoutConstraint.activate([
            pl.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 10),
            pl.topAnchor.constraint(equalTo: tv.topAnchor, constant: 8),
            pl.trailingAnchor.constraint(lessThanOrEqualTo: tv.trailingAnchor, constant: -10)
        ])
        pl.isHidden = !text.isEmpty

        return tv
    }

    func updateUIView(_ uiView: EagerFirstResponderTextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
            context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
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
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
    }
}
