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
    @Published var excludedCount: Int = 0
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
        recordForUndo()
        let oldestAddedId = newClips.min { $0.sortKeyMs < $1.sortKeyMs }?.id

        var result = clips
        for clip in newClips.sorted(by: { $0.sortKeyMs < $1.sortKeyMs }) {
            let index = result.firstIndex { $0.sortKeyMs > clip.sortKeyMs } ?? result.count
            result.insert(clip, at: index)
        }
        clips = result

        if let id = oldestAddedId, let index = clips.firstIndex(where: { $0.id == id }) {
            selectedIndex = index
        }
        scheduleAutoSave()
    }

    func deleteClip(at index: Int) {
        guard clips.indices.contains(index) else { return }
        recordForUndo()
        clips.remove(at: index)
        if clips.isEmpty {
            selectedIndex = nil
        } else if let si = selectedIndex {
            selectedIndex = min(si, clips.count - 1)
        }
        scheduleAutoSave()
    }

    func deleteAllClips() {
        recordForUndo()
        clips.removeAll()
        selectedIndex = nil
        scheduleAutoSave()
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
        recordForUndo()
        let clip = clips.remove(at: from)
        clips.insert(clip, at: to)
        if selectedIndex == from {
            selectedIndex = to
        } else if let si = selectedIndex {
            if from < to, si > from, si <= to { selectedIndex = si - 1 }
            else if from > to, si >= to, si < from { selectedIndex = si + 1 }
        }
        scheduleAutoSave()
    }

    // MARK: - Trim

    func updateTrim(startMs: Int64, endMs: Int64) {
        guard var clip = selectedClip, let i = selectedIndex else { return }
        recordForUndo(tag: "trim:\(i)")
        clip.startMs = startMs
        clip.endMs   = endMs
        updateSelectedClip(clip)
        scheduleAutoSave()
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
        guard var clip = selectedClip else { return nil }
        let span = clip.trimmedDurationMs
        guard span > 0 else { return nil }

        let maxStart = max(0, clip.durationMs - span)
        let newStart = min(max(targetStartMs, 0), maxStart)
        guard newStart != clip.startMs else { return (clip.startMs, clip.endMs) }
        let delta   = newStart - clip.startMs
        let newEnd  = newStart + span

        recordForUndo(tag: "trimMove:\(selectedIndex ?? -1)")
        clip.startMs = newStart
        clip.endMs   = newEnd
        clip.texts = clip.texts.map { seg in
            guard seg.startMs != 0 else { return seg }
            var s = seg
            s.startMs = min(max(seg.startMs + delta, 1), max(clip.durationMs, 1))
            return s
        }
        updateSelectedClip(clip)
        scheduleAutoSave()
        return (newStart, newEnd)
    }

    /// ひとことの区切りをひとつ、時間軸上で動かす（Android: moveSplit）。
    /// 前後の区切り（無ければクリップの端／トリム終端）を越えないようクランプする。
    @discardableResult
    func moveSplit(index: Int, newAtMs: Int64) -> Int64? {
        guard var clip = selectedClip, clip.texts.indices.contains(index), index != 0 else { return nil }
        let minGap = VlogClip.splitMinDistanceMs
        let lowerBound = clip.texts[index - 1].startMs + minGap
        let upperBound = (clip.texts.indices.contains(index + 1) ? clip.texts[index + 1].startMs : clip.endMs) - minGap
        guard lowerBound <= upperBound else { return nil }

        let clamped = min(max(newAtMs, lowerBound), upperBound)
        guard clamped != clip.texts[index].startMs else { return clamped }

        recordForUndo(tag: "splitMove:\(selectedIndex ?? -1):\(index)")
        clip.texts[index].startMs = clamped
        updateSelectedClip(clip)
        scheduleAutoSave()
        return clamped
    }

    // MARK: - Text / Split

    func updateText(_ text: String, segmentIndex: Int) {
        guard var clip = selectedClip, let i = selectedIndex else { return }
        guard clip.texts.indices.contains(segmentIndex) else { return }
        recordForUndo(tag: "text:\(i):\(segmentIndex)")
        clip.texts[segmentIndex].text = text
        updateSelectedClip(clip)
        scheduleAutoSave()
    }

    /// Inserts a split at positionMs. Returns the new segment index on success.
    @discardableResult
    func splitAt(positionMs: Int64) -> Int? {
        guard var clip = selectedClip else { return nil }
        let minDist = VlogClip.splitMinDistanceMs
        guard positionMs - clip.startMs >= minDist,
              clip.endMs - positionMs >= minDist else { return nil }
        for pt in clip.splitPoints where abs(pt - positionMs) < minDist { return nil }

        recordForUndo()
        let newSeg = TextSegment(startMs: positionMs, text: "ひとこと")
        let insertIdx = clip.texts.firstIndex(where: { $0.startMs > positionMs }) ?? clip.texts.count
        clip.texts.insert(newSeg, at: insertIdx)
        updateSelectedClip(clip)
        scheduleAutoSave()
        return insertIdx
    }

    func removeSplitNear(positionMs: Int64) {
        guard var clip = selectedClip else { return }
        guard let splitMs = clip.splitPointNear(positionMs: positionMs) else { return }
        recordForUndo()
        clip.texts.removeAll { $0.startMs == splitMs }
        updateSelectedClip(clip)
        scheduleAutoSave()
    }

    // MARK: - Continuous play

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
        recordForUndo(tag: "mute:\(index)")
        clips[index].isMuted.toggle()
        scheduleAutoSave()
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
        clips         = loaded
        excludedCount = excluded
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
        recordForUndo()
        clips         = project.clips
        selectedIndex = clips.isEmpty ? nil : 0
        scheduleAutoSave()
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
