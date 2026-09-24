import Foundation

/// 数秒後に自動で消えるトースト通知の、タイマー部分だけを共通化したもの。
/// VlogStore.toastMessageとExportManager.toastMessageは、いずれも
/// @Publishedのまま各クラスに持たせている（SwiftUIの購読を素直に保つため）。
/// 重複していたのは「しばらく待ってからnilに戻す」というタイマー処理だけなので、
/// そこだけをここへ切り出す。
enum ToastTimer {
    /// `seconds`秒後に`clear`を呼ぶタスクを返す。呼び出し側は、新しいトーストを出す前に
    /// 前回のタスクをキャンセルしてから使うこと。
    /// 長い文言（開けない動画・空き容量の案内など）は読み切る前に消えないよう、長めに出す
    /// （Android は Toast.LENGTH_LONG ＝ 約3.5秒。こちらは文字数で伸ばす）
    static func duration(for text: String) -> Double {
        min(8, max(3.5, Double(text.count) / 12))
    }

    static func scheduleClear(after seconds: Double = 3.5, clear: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { clear() }
        }
    }
}
