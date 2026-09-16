import SwiftUI

/// 書き出し中の進捗バー・メッセージ。Android版ExportProgress（PreviewSection.kt）と同じく、
/// 画面全体を覆うオーバーレイにはせず操作ボタンの下に差し込むだけにして、
/// 編集画面（プレビュー・タイムライン・ひとこと欄）はそのまま見える・触れる状態を保つ。
/// 中止はActionButtons側の「中止」ボタン（書き出しボタンの入れ替わり）が担うので、ここには置かない。
struct ExportProgressView: View {
    @EnvironmentObject var exportManager: ExportManager
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: exportManager.progress)
                .progressViewStyle(.linear)
                .tint(AppColors.primary(colorScheme))
            Text(exportManager.message)
                .font(.system(size: 12))
                .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                .contentTransition(.opacity)
                .animation(.default, value: exportManager.message)
        }
    }
}
