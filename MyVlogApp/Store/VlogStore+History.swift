import Foundation

// =====================================================================================
// VlogStore.swiftからの切り出し。undo/redo履歴の管理だけをまとめたもの
// （Android: edit/EditHistory.kt）。
// undoStack/redoStack/maxUndo/lastTagの実体（stored property）はSwiftの制約上
// extensionへ置けないため、VlogStore.swift本体の型定義に残っている。
// =====================================================================================

/// 同種の連続編集をひとつの履歴にまとめる時間。
/// つまみを1回ドラッグしただけで数十件積まれると、「もとに戻す」を何度押しても
/// 元に戻らなくなるため（Android: HISTORY_COALESCE_MS）。
private let historyCoalesceSeconds: TimeInterval = 0.9

struct AppSnapshot: Equatable {
    var clips: [VlogClip]
    var selectedIndex: Int?
}

struct UndoEntry {
    var snapshot: AppSnapshot
    var tag: String?
}

extension VlogStore {
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// まとめ判定に使う時刻。
    ///
    /// 壁時計（Date）ではなく端末の起動からの経過時間を使う。時刻合わせや
    /// タイムゾーン変更で壁時計が巻き戻ると、まとめ判定が意図せず効いたり
    /// 効かなかったりするため（Android: SystemClock.elapsedRealtime）。
    private var historyNow: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// 変更を加える「直前」に呼ぶ。
    ///
    /// - Parameter tag: 同じタグの編集が`historyCoalesceSeconds`以内に**続けて**来た場合はまとめる。
    ///   つまみのドラッグや文字入力のように連続で飛んでくる編集に付ける。
    ///   nilを渡すと必ず1件として積まれる（追加・削除・並べ替えなど一発で完結する操作）。
    func recordForUndo(tag: String? = nil) {
        let now = historyNow
        if let tag, tag == lastTag, now - lastTagAt < historyCoalesceSeconds {
            lastTagAt = now
            return
        }

        undoStack.append(UndoEntry(snapshot: AppSnapshot(clips: clips, selectedIndex: selectedIndex), tag: tag))
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()

        lastTag   = tag
        lastTagAt = now
    }

    func undo() {
        guard !undoStack.isEmpty else { return }
        let current = AppSnapshot(clips: clips, selectedIndex: selectedIndex)
        redoStack.append(UndoEntry(snapshot: current, tag: nil))
        apply(undoStack.removeLast().snapshot)
    }

    func redo() {
        guard !redoStack.isEmpty else { return }
        let current = AppSnapshot(clips: clips, selectedIndex: selectedIndex)
        undoStack.append(UndoEntry(snapshot: current, tag: nil))
        apply(redoStack.removeLast().snapshot)
    }

    /// 履歴を空にする。復元直後など「ここを起点にしたい」場面で呼ぶ（Android: clear）
    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        resetCoalescing()
    }

    /// まとめ判定をリセットする。
    ///
    /// undo/redoの直後に呼ばないと、戻した直後の同じタグの編集が「続きの操作」と
    /// みなされてまとめられ、その編集が履歴に積まれない（もう一度戻せない）。
    private func resetCoalescing() {
        lastTag   = nil
        lastTagAt = 0
    }

    private func apply(_ snap: AppSnapshot) {
        clips = snap.clips
        selectedIndex = snap.selectedIndex
        resetCoalescing()
        scheduleAutoSave()
    }
}
