import UIKit

/// UIApplication.beginBackgroundTask/endBackgroundTaskの対になった呼び出しをまとめたもの。
/// ExportManager（書き出し）とContentView+Import（動画インポート）で同じ形のペアが
/// それぞれ独立に書かれていたのをここへ集約する。
final class BackgroundTaskGuard {
    private var id: UIBackgroundTaskIdentifier = .invalid

    /// nameはInstruments等で見分けるための識別名。onExpiredはOSが与えた延長時間を
    /// 使い切ったときに呼ばれる（ここで進行中の処理をキャンセルする）。
    func begin(name: String, onExpired: @escaping () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: onExpired)
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
