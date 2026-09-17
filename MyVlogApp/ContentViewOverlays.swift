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
                .font(.system(size: 13))
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
    }
}
