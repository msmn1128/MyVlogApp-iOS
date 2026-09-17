import Foundation
import Photos

// =====================================================================================
// VlogStore.swiftからの切り出し。自動保存・名前付き保存(SavedProject)の永続化だけを
// まとめたもの（Android: ClipStore.ktと同じ、永続化をViewModel本体から分離する考え方）。
// autoSaveTask/autoSaveKey/savedProjectsKeyの実体（stored property）はSwiftの制約上
// extensionへ置けないため、VlogStore.swift本体の型定義に残っている。
// =====================================================================================

extension VlogStore {
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

    /// VlogStore.swift本体のinit()から呼ぶためinternal
    func restoreAutoSave() async {
        guard let data   = UserDefaults.standard.data(forKey: autoSaveKey + "_clips"),
              let saved  = try? JSONDecoder().decode([VlogClip].self, from: data) else { return }
        let savedIndex   = UserDefaults.standard.object(forKey: autoSaveKey + "_index") as? Int

        let (loaded, excluded) = validClips(from: saved)
        clips = loaded
        if let si = savedIndex, loaded.indices.contains(si) { selectedIndex = si }
        else if !loaded.isEmpty { selectedIndex = 0 }

        if excluded > 0 {
            showMessage("\(excluded) 件の動画は復元できませんでした（移動・削除されたか、アクセス権限が取り消されています）")
        }
    }

    /// 各クリップの参照先（ファイル存在／PHAsset存在）を検証し、無効なものを除外する。
    /// restoreAutoSave/loadProjectの両方から使う（Android: ClipStoreのreadableチェックと同じ役割）。
    /// 以前はloadProjectだけこの検証を通らず、動画を削除・移動した後に古い名前付き保存を
    /// 読み込むと無効な参照を含んだまま復元されてしまっていた。
    private func validClips(from source: [VlogClip]) -> (clips: [VlogClip], excludedCount: Int) {
        var loaded: [VlogClip] = []
        var excluded = 0
        for var clip in source {
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
        return (loaded, excluded)
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
        let (loaded, excluded) = validClips(from: project.clips)
        mutateClips {
            clips         = loaded
            selectedIndex = loaded.isEmpty ? nil : 0
        }
        if excluded > 0 {
            showMessage("\(excluded) 件の動画は復元できませんでした（移動・削除されたか、アクセス権限が取り消されています）")
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

    /// VlogStore.swift本体のinit()から呼ぶためinternal
    func loadSavedProjectsFromDefaults() {
        guard let data     = UserDefaults.standard.data(forKey: savedProjectsKey),
              let projects = try? JSONDecoder().decode([SavedProject].self, from: data) else { return }
        savedProjects = projects.sorted { $0.savedAt > $1.savedAt }
    }
}
