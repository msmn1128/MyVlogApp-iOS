import SwiftUI

/// 書き出し中の進捗バー・メッセージ。Android版ExportProgress（PreviewSection.kt）と同じく、
/// 画面全体を覆うオーバーレイにはせず操作ボタンの下に差し込むだけにして、
/// 編集画面（プレビュー・タイムライン・ひとこと欄）はそのまま見える・触れる状態を保つ。
/// 中止はActionButtons側の「中止」ボタン（書き出しボタンの入れ替わり）が担うので、ここには置かない。
struct ExportProgressView: View {
    @Environment(ExportManager.self) private var exportManager
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: exportManager.progress)
                .progressViewStyle(.linear)
                .tint(AppColors.primary(colorScheme))
                // 書き出しが始まったことをUIテストから確かめるための目印
                // （MyVlogAppUITests/ExportUITests.swift）
                .accessibilityIdentifier("exportProgress")
                // 進捗バーだけでは何の進捗か分からないので、下の文言を読み上げの値にする
                .accessibilityLabel("書き出しの進捗")
                .accessibilityValue(exportManager.message)
            Text(exportManager.message)
                .vlogFont(12)
                .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                .contentTransition(.opacity)
                .animation(.default, value: exportManager.message)
        }
    }
}
