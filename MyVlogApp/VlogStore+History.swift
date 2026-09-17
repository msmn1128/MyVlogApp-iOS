import Foundation

// =====================================================================================
// VlogStore.swiftからの切り出し。undo/redo履歴の管理だけをまとめたもの。
// undoStack/redoStack/maxUndo/lastTagSeenの実体（stored property）はSwiftの制約上
// extensionへ置けないため、VlogStore.swift本体の型定義に残っている。
// =====================================================================================

struct AppSnapshot: Equatable {
    var clips: [VlogClip]
    var selectedIndex: Int?
}

struct UndoEntry {
    var snapshot: AppSnapshot
    var tag: String?
    var timestamp: Date
}

extension VlogStore {
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Call BEFORE making any change. Saves the current state for undo.
    /// Debounced: if the same tag is seen again within 900 ms, the entry is NOT duplicated.
    func recordForUndo(tag: String? = nil) {
        let now = Date()
        if let tag {
            let last = lastTagSeen[tag]
            lastTagSeen[tag] = now
            if let last, now.timeIntervalSince(last) < 0.9 {
                redoStack.removeAll()
                return
            }
        }
        let snap = AppSnapshot(clips: clips, selectedIndex: selectedIndex)
        undoStack.append(UndoEntry(snapshot: snap, tag: tag, timestamp: now))
        if undoStack.count > maxUndo { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard !undoStack.isEmpty else { return }
        let current = AppSnapshot(clips: clips, selectedIndex: selectedIndex)
        redoStack.append(UndoEntry(snapshot: current, tag: nil, timestamp: Date()))
        apply(undoStack.removeLast().snapshot)
    }

    func redo() {
        guard !redoStack.isEmpty else { return }
        let current = AppSnapshot(clips: clips, selectedIndex: selectedIndex)
        undoStack.append(UndoEntry(snapshot: current, tag: nil, timestamp: Date()))
        apply(redoStack.removeLast().snapshot)
    }

    private func apply(_ snap: AppSnapshot) {
        clips = snap.clips
        selectedIndex = snap.selectedIndex
        scheduleAutoSave()
    }
}
