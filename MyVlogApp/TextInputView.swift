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
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                // Segment indicator
                HStack {
                    if let clip = store.selectedClip, clip.texts.count > 1 {
                        Text("区間 \(segmentIndex + 1)/\(clip.texts.count)")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(AppColors.primary)
                    } else {
                        Text("テロップ")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)

                // Native UITextView - 実機で100%確実にキーボードが開く
                NativeTextView(
                    text: $text,
                    placeholder: store.selectedClip == nil ? "動画を選択してください" : "テロップを入力...",
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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.systemFont(ofSize: 15)
        tv.backgroundColor = .clear
        tv.textColor = UIColor.label
        tv.text = text
        tv.isScrollEnabled = true
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)

        // Toolbar with Done button
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "閉じる", style: .done, target: tv, action: #selector(UIResponder.resignFirstResponder))
        done.tintColor = UIColor(AppColors.primary)
        toolbar.items = [flex, done]
        toolbar.sizeToFit()
        tv.inputAccessoryView = toolbar

        // Placeholder label
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

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
            context.coordinator.placeholderLabel?.isHidden = !text.isEmpty
        }
        context.coordinator.placeholderLabel?.text = placeholder
    }
}
