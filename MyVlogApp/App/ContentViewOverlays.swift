import SwiftUI

// =====================================================================================
// ContentView.swiftからの切り出し。画面全体に重なるオーバーレイView（トースト通知・
// インポート中の進捗）だけをまとめたもの。
// =====================================================================================

// MARK: - Toast（Android: Toast相当の一時的な通知）

struct ToastView: View {
    let text: String

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .vlogFont(13)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.black.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.bottom, 24)
                .padding(.horizontal, 24)
                .transition(.opacity)
        }
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.2), value: text)
        // 数秒で消えてしまうので、VoiceOver利用時はその場で読み上げてもらう。
        // 触って探しに行く形だと、たどり着く前に消えてしまう
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
        .onChange(of: text) { _, newValue in
            AccessibilityNotification.Announcement(newValue).post()
        }
        .onAppear { AccessibilityNotification.Announcement(text).post() }
    }
}

// MARK: - Import overlay

struct ImportOverlayView: View {
    let progress: Double
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(AppColors.primary)
                    .frame(width: 260)
                Text(message)
                    .foregroundStyle(.white)
                    .font(.subheadline)
            }
            .padding(28)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        // 読み込み中は画面全体を覆って操作を受け付けないので、VoiceOverにも
        // 「いま何が起きているか」だけを1項目で伝え、後ろの編集画面は読ませない
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("動画を読み込み中")
        .accessibilityValue(message)
    }
}
