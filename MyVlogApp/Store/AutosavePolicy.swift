import Foundation

/// 前回の続き（自動保存）を、いつ書き換えてよいか（Android: AutosavePolicy.kt）。
///
/// 決まりは2つ:
/// - 復元が済むまでは書かない。済む前に書くと、復元前の空の一覧で前回の内容を上書きしてしまう。
/// - 復元で開けない動画を落とした回は、何か編集するまで書かない。開けなかったのが一時的なこと
///   （写真へのアクセスを「選択した写真のみ」に変えた・iCloudの動画がオフラインだった）はよくある。
///   開けた分だけを書き戻すと、落とした動画の編集内容が保存からも消え、アクセスを許可し直しても
///   続きが戻らなくなる。編集は必ず「もとに戻す」の履歴に積まれる（撮影時刻の取り直しは積まれない）
///   ので、それが押せるようになったことを編集の合図にする。
///
/// 判断だけを持つ値型で、VlogStoreから切り出してあるのは単体テストで守るため。
nonisolated struct AutosavePolicy {
    private var restored = false
    private var keepStoredUntilEdited = false

    /// 前回の続きの復元が済んだ。`droppedCount`は開けなくて落とした動画の本数
    mutating func onRestored(droppedCount: Int) {
        restored = true
        keepStoredUntilEdited = droppedCount > 0
    }

    /// 一覧が変わるたびの自動保存で、書いてよいか。
    /// 編集の合図（`canUndo`）を一度受け取ったら、以後は保留しない。
    mutating func shouldSave(canUndo: Bool) -> Bool {
        guard restored else { return false }
        if keepStoredUntilEdited {
            guard canUndo else { return false }
            keepStoredUntilEdited = false
        }
        return true
    }

    /// アプリがバックグラウンドへ回るとき（自動保存の待ちが打ち切られうる）に、最後の状態を書いてよいか。
    /// `canUndo`も見るのは、編集した直後に回ると、自動保存側が編集の合図を受け取って
    /// 保留を解く前にここへ来ることがあるため。
    func shouldSaveOnExit(canUndo: Bool) -> Bool {
        restored && (!keepStoredUntilEdited || canUndo)
    }
}
