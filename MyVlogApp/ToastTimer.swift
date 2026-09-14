import Foundation

/// 数秒後に自動で消えるトースト通知の、タイマー部分だけを共通化したもの。
/// VlogStore.toastMessageとExportManager.toastMessageは、いずれも
/// @Publishedのまま各クラスに持たせている（SwiftUIの購読を素直に保つため）。
/// 重複していたのは「3秒待ってからnilに戻す」というタイマー処理だけなので、
/// そこだけをここへ切り出す。
enum ToastTimer {
    /// 3秒後に`clear`を呼ぶタスクを返す。呼び出し側は、新しいトーストを出す前に
    /// 前回のタスクをキャンセルしてから使うこと。
    static func scheduleClear(after seconds: UInt64 = 3, clear: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { clear() }
        }
    }
}
