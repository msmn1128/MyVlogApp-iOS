import SwiftUI
import Combine
import Photos

// MARK: - Undo internals

private struct AppSnapshot: Equatable {
    var clips: [VlogClip]
    var selectedIndex: Int?
}

private struct UndoEntry {
    var snapshot: AppSnapshot
    var tag: String?
    var timestamp: Date
}

// MARK: - VlogStore

@MainActor
class VlogStore: ObservableObject {
    // MARK: Published state
    @Published var clips: [VlogClip] = []
    @Published var selectedIndex: Int? = nil
    @Published var isContinuousPlay: Bool
    @Published var savedProjects: [SavedProject] = []
    /// 一時的な通知メッセージ（Android: VlogEvent.Message / Toast相当）
    @Published var toastMessage: String? = nil
    private var toastTask: Task<Void, Never>?
    /// タイムライン全体のミュート。クリップ個別の`isMuted`とは独立していて、
    /// こちらがonの間はどのクリップも音声が出ない（Android: VlogViewModel.timelineMuted）
    @Published var timelineMuted: Bool

    // MARK: Undo / Redo
    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private let maxUndo = 50
    /// Tracks when each debounce-tag was last seen (not just when entry was added)
    private var lastTagSeen: [String: Date] = [:]

    // MARK: Persistence
    private var autoSaveTask: Task<Void, Never>?
    private let autoSaveKey     = "vlog_autosave_v1"
    private let savedProjectsKey = "vlog_saved_projects_v1"
    private let continuousPlayKey = "vlog_continuous_play"
    private let timelineMutedKey  = "vlog_timeline_muted"

    init() {
        isContinuousPlay = UserDefaults.standard.bool(forKey: "vlog_continuous_play")
        timelineMuted    = UserDefaults.standard.bool(forKey: "vlog_timeline_muted")
        loadSavedProjectsFromDefaults()
        Task { await restoreAutoSave() }
    }

    // MARK: - Computed helpers

    var selectedClip: VlogClip? {
        guard let i = selectedIndex, clips.indices.contains(i) else { return nil }
        return clips[i]
    }

    func updateSelectedClip(_ clip: VlogClip) {
        guard let i = selectedIndex, clips.indices.contains(i) else { return }
        clips[i] = clip
    }

    /// 選択中クリップの変更の定型（履歴記録→変更→反映→自動保存）を1か所にまとめる
    /// （Android: VlogViewModel.updateSelected{}）。
    /// ⚠️ 事前バリデーションで「何もしない」場合がある操作（moveTrim/moveSplit/splitAt）は、
    /// 変更が実際にあるかどうかの判定を済ませてから呼ぶこと。ここに入った時点で
    /// 必ず履歴が1件積まれる（無駄なundoスタック消費を避けるため）。
    private func updateSelected(tag: String? = nil, _ transform: (inout VlogClip) -> Void) {
        guard var clip = selectedClip else { return }
        recordForUndo(tag: tag)
        transform(&clip)
        updateSelectedClip(clip)
        scheduleAutoSave()
    }

    /// clips配列そのものを触る操作（追加・削除・並べ替え・ミュート）の定型
    private func mutateClips(tag: String? = nil, _ body: () -> Void) {
        recordForUndo(tag: tag)
        body()
        scheduleAutoSave()
    }

    // MARK: - Undo / Redo public

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

    // MARK: - Clip operations

    /// 撮影/作成日時順になる位置へ追加し、追加した中で最も古いものを選択する（Android: addClips/mergeByShotAt）
    func addClips(_ newClips: [VlogClip]) {
        guard !newClips.isEmpty else { return }
        let oldestAddedId = newClips.min { $0.sortKeyMs < $1.sortKeyMs }?.id

        mutateClips {
            var result = clips
            for clip in newClips.sorted(by: { $0.sortKeyMs < $1.sortKeyMs }) {
                let index = result.firstIndex { $0.sortKeyMs > clip.sortKeyMs } ?? result.count
                result.insert(clip, at: index)
            }
            clips = result

            if let id = oldestAddedId, let index = clips.firstIndex(where: { $0.id == id }) {
                selectedIndex = index
            }
        }
    }

    func deleteClip(at index: Int) {
        guard clips.indices.contains(index) else { return }
        mutateClips {
            clips.remove(at: index)
            if clips.isEmpty {
                selectedIndex = nil
            } else if let si = selectedIndex {
                selectedIndex = min(si, clips.count - 1)
            }
        }
    }

    func deleteAllClips() {
        mutateClips {
            clips.removeAll()
            selectedIndex = nil
        }
    }

    func moveClipLeft() {
        guard let i = selectedIndex, i > 0 else { return }
        moveClip(from: i, to: i - 1)
    }

    func moveClipRight() {
        guard let i = selectedIndex, i < clips.count - 1 else { return }
        moveClip(from: i, to: i + 1)
    }

    private func moveClip(from: Int, to: Int) {
        mutateClips {
            let clip = clips.remove(at: from)
            clips.insert(clip, at: to)
            if selectedIndex == from {
                selectedIndex = to
            } else if let si = selectedIndex {
                if from < to, si > from, si <= to { selectedIndex = si - 1 }
                else if from > to, si >= to, si < from { selectedIndex = si + 1 }
            }
        }
    }

    // MARK: - Trim

    func updateTrim(startMs: Int64, endMs: Int64) {
        guard let i = selectedIndex else { return }
        updateSelected(tag: "trim:\(i)") { clip in
            clip.startMs = startMs
            clip.endMs   = endMs
        }
    }

    /// 先頭から指定の長さだけトリムする（Android: applyTrimPreset）
    func applyTrimPreset(lengthMs: Int64) {
        guard let clip = selectedClip, clip.durationMs > 0 else { return }
        let startMs = min(max(clip.startMs, 0), clip.durationMs)
        updateTrim(startMs: startMs, endMs: min(startMs + lengthMs, clip.durationMs))
    }

    /// トリミング区間を長さそのままで前後に移動する（Android: moveTrim）。
    /// ひとことの区切り（先頭は除く）も同じ分だけ一緒にずらす。
    @discardableResult
    func moveTrim(targetStartMs: Int64) -> (startMs: Int64, endMs: Int64)? {
        guard let clip = selectedClip else { return nil }
        let span = clip.trimmedDurationMs
        guard span > 0 else { return nil }

        let maxStart = max(0, clip.durationMs - span)
        let newStart = min(max(targetStartMs, 0), maxStart)
        guard newStart != clip.startMs else { return (clip.startMs, clip.endMs) }
        let delta  = newStart - clip.startMs
        let newEnd = newStart + span

        updateSelected(tag: "trimMove:\(selectedIndex ?? -1)") { c in
            c.startMs = newStart
            c.endMs   = newEnd
            c.texts = c.texts.map { seg in
                guard seg.startMs != 0 else { return seg }
                var s = seg
                s.startMs = min(max(seg.startMs + delta, 1), max(c.durationMs, 1))
                return s
            }
        }
        return (newStart, newEnd)
    }

    /// ひとことの区切りをひとつ、時間軸上で動かす（Android: moveSplit）。
    /// 前後の区切り（無ければクリップの端／トリム終端）を越えないようクランプする。
    @discardableResult
    func moveSplit(index: Int, newAtMs: Int64) -> Int64? {
        guard let clip = selectedClip, clip.texts.indices.contains(index), index != 0 else { return nil }
        let minGap = VlogClip.splitMinDistanceMs
        let lowerBound = clip.texts[index - 1].startMs + minGap
        let upperBound = (clip.texts.indices.contains(index + 1) ? clip.texts[index + 1].startMs : clip.endMs) - minGap
        guard lowerBound <= upperBound else { return nil }

        let clamped = min(max(newAtMs, lowerBound), upperBound)
        guard clamped != clip.texts[index].startMs else { return clamped }

        updateSelected(tag: "splitMove:\(selectedIndex ?? -1):\(index)") { c in
            c.texts[index].startMs = clamped
        }
        return clamped
    }

    // MARK: - Text / Split

    func updateText(_ text: String, segmentIndex: Int) {
        guard let i = selectedIndex, let clip = selectedClip,
              clip.texts.indices.contains(segmentIndex) else { return }
        updateSelected(tag: "text:\(i):\(segmentIndex)") { c in
            c.texts[segmentIndex].text = text
        }
    }

    /// Inserts a split at positionMs. Returns the new segment index on success.
    @discardableResult
    func splitAt(positionMs: Int64) -> Int? {
        guard let clip = selectedClip else { return nil }
        let minDist = VlogClip.splitMinDistanceMs
        guard positionMs - clip.startMs >= minDist,
              clip.endMs - positionMs >= minDist else { return nil }
        for pt in clip.splitPoints where abs(pt - positionMs) < minDist { return nil }

        let newSeg = TextSegment(startMs: positionMs, text: "ひとこと")
        let insertIdx = clip.texts.firstIndex(where: { $0.startMs > positionMs }) ?? clip.texts.count
        updateSelected { c in
            c.texts.insert(newSeg, at: insertIdx)
        }
        return insertIdx
    }

    func removeSplitNear(positionMs: Int64) {
        guard let clip = selectedClip, let splitMs = clip.splitPointNear(positionMs: positionMs) else { return }
        updateSelected { c in
            c.texts.removeAll { $0.startMs == splitMs }
        }
    }

    // MARK: - Continuous play

    // toggleContinuousPlay/toggleTimelineMutedはrecordForUndo/scheduleAutoSaveを
    // 経由しない。これはクリップのデータではなく「アプリの設定」（UserDefaultsに
    // 直接保存）だから。autosaveはclips/selectedIndexしか対象にしておらず、undo
    // スタックもクリップの編集履歴のためのものなので、意図的にどちらも通さない
    // （toggleMute(at:)はclips[index].isMutedというクリップ自身のデータなので
    // 対照的にrecordForUndo/scheduleAutoSaveの対象になる）。
    func toggleContinuousPlay() {
        isContinuousPlay.toggle()
        UserDefaults.standard.set(isContinuousPlay, forKey: continuousPlayKey)
    }

    // MARK: - Mute

    func toggleTimelineMuted() {
        timelineMuted.toggle()
        UserDefaults.standard.set(timelineMuted, forKey: timelineMutedKey)
    }

    func toggleMute(at index: Int) {
        guard clips.indices.contains(index) else { return }
        mutateClips(tag: "mute:\(index)") {
            clips[index].isMuted.toggle()
        }
    }

    // MARK: - Toast

    /// 数秒で自動的に消える通知メッセージを出す（Android: Toast相当）
    func showMessage(_ text: String) {
        toastTask?.cancel()
        toastMessage = text
        toastTask = ToastTimer.scheduleClear { [weak self] in self?.toastMessage = nil }
    }

    // MARK: - Auto-save

    func scheduleAutoSave() {
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.performAutoSave()
        }
    }

    private func performAutoSave() async {
        guard let data = try? JSONEncoder().encode(clips) else { return }
        UserDefaults.standard.set(data,           forKey: autoSaveKey + "_clips")
        UserDefaults.standard.set(selectedIndex,  forKey: autoSaveKey + "_index")
    }

    private func restoreAutoSave() async {
        guard let data   = UserDefaults.standard.data(forKey: autoSaveKey + "_clips"),
              let saved  = try? JSONDecoder().decode([VlogClip].self, from: data) else { return }
        let savedIndex   = UserDefaults.standard.object(forKey: autoSaveKey + "_index") as? Int

        var loaded: [VlogClip] = []
        var excluded = 0
        for var clip in saved {
            if let resolved = clip.resolvedFileURL, FileManager.default.fileExists(atPath: resolved.path) {
                if clip.relativeFilePath == nil {
                    clip.relativeFilePath = resolved.lastPathComponent
                }
                clip.fileURL = resolved
                loaded.append(clip)
            } else if let id = clip.assetIdentifier, PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count > 0 {
                loaded.append(clip)
            } else {
                excluded += 1
            }
        }
        clips = loaded
        if let si = savedIndex, loaded.indices.contains(si) { selectedIndex = si }
        else if !loaded.isEmpty { selectedIndex = 0 }

        if excluded > 0 {
            showMessage("\(excluded) 件の動画は復元できませんでした（移動・削除されたか、アクセス権限が取り消されています）")
        }
    }

    // MARK: - Named saves

    func saveCurrentProject(name: String) -> Bool {
        guard savedProjects.count < 20 else { return false }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        savedProjects.insert(makeSavedProject(id: now, name: name, savedAt: now), at: 0)
        persistSavedProjects()
        return true
    }

    func loadProject(_ project: SavedProject) {
        mutateClips {
            clips         = project.clips
            selectedIndex = clips.isEmpty ? nil : 0
        }
    }

    /// 既存の保存を、名前とidはそのままに現在の編集内容で上書きする（Android: overwriteProject）
    func overwriteProject(id: Int64, name: String) {
        guard let idx = savedProjects.firstIndex(where: { $0.id == id }) else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        savedProjects[idx] = makeSavedProject(id: id, name: name, savedAt: now)
        persistSavedProjects()
    }

    /// 現在編集中のclipsから、指定id/name/savedAtでSavedProjectを組み立てる
    /// （saveCurrentProject/overwriteProjectで共通の構築ロジック）
    private func makeSavedProject(id: Int64, name: String, savedAt: Int64) -> SavedProject {
        SavedProject(
            id:        id,
            name:      name,
            savedAt:   savedAt,
            clipCount: clips.count,
            totalMs:   clips.reduce(0) { $0 + $1.trimmedDurationMs },
            clips:     clips
        )
    }

    func deleteSavedProject(id: Int64) {
        savedProjects.removeAll { $0.id == id }
        persistSavedProjects()
    }

    private func persistSavedProjects() {
        guard let data = try? JSONEncoder().encode(savedProjects) else { return }
        UserDefaults.standard.set(data, forKey: savedProjectsKey)
    }

    private func loadSavedProjectsFromDefaults() {
        guard let data     = UserDefaults.standard.data(forKey: savedProjectsKey),
              let projects = try? JSONDecoder().decode([SavedProject].self, from: data) else { return }
        savedProjects = projects.sorted { $0.savedAt > $1.savedAt }
    }
}
