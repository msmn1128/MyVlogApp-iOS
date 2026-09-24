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

// MARK: - Import progress

/// 動画を読み込んでいる間の進捗。書き出しの進捗（ExportProgressView）と同じく、操作ボタンの下に
/// 差し込むだけにする（Android: PreviewSection.kt AddProgress）。
///
/// 以前は画面全体を覆うオーバーレイで、読み込みが終わるまで編集できなかった。読み込んだ動画は
/// 終わったときの一覧へ撮影日時順に差し込むので、その間に編集していても壊れない。追加・保存・
/// 書き出しだけは、読み込み中のタイムラインが途中の状態なので止める（ActionButtons）。
struct ImportProgressView: View {
    let progress: Double
    let message: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .tint(AppColors.primary(colorScheme))
            Text(message)
                .vlogFont(12)
                .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                .contentTransition(.numericText())
        }
        // 進捗バーと文言を1つの項目にして、何の進捗かを読み上げる
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("動画を読み込み中")
        .accessibilityValue(message)
    }
}
