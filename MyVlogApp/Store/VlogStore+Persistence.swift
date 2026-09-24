import Foundation
import Photos

// =====================================================================================
// VlogStore.swiftからの切り出し。自動保存・名前付き保存(SavedProject)の永続化だけを
// まとめたもの（Android: ClipStore.kt / ProjectsController.kt と同じ、永続化を
// ViewModel本体から分離する考え方）。
// autoSaveTask/autoSaveKey/savedProjectsKeyの実体（stored property）はSwiftの制約上
// extensionへ置けないため、VlogStore.swift本体の型定義に残っている。
// =====================================================================================

/// 自動保存の書き込みを1本の直列なレーンにまとめる。
///
/// 以前は保存のたびに`Task.detached`を起こしていたが、detached task同士の実行順は
/// 保証されない。デバウンスをまたいで続けて2回走ると、古いスナップショットのほうが
/// あとからUserDefaultsへ届き、直前の編集を巻き戻して保存してしまう形になりえた。
/// 直列キューは積んだ順にそのまま実行されるので、最後に投げた内容が必ず最後に残る。
private nonisolated let autoSaveQueue = DispatchQueue(label: "com.msmn1128.myvlogapp.autosave", qos: .utility)

/// `UserDefaults`を別スレッドへ渡すための入れ物。
///
/// `UserDefaults`はAppleのドキュメントでスレッドセーフと明記されているが、型としては
/// Sendableではないため、そのままクロージャへ持ち込むと並行性チェックに引っかかる
/// （Swift 6モードではエラー）。安全である根拠をこの1箇所に閉じ込めて@unchecked Sendableにする。
private struct SendableDefaults: @unchecked Sendable {
    let defaults: UserDefaults
}

extension VlogStore {
    // MARK: - Auto-save

    func scheduleAutoSave() {
        // 開けない動画を落として復元した回は、編集されるまで書き換えない（理由はAutosavePolicy）
        guard autosavePolicy.shouldSave(canUndo: canUndo) else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.autoSaveTask = nil
            self.performAutoSave()
        }
    }

    /// アプリがバックグラウンドへ回るときに、待っている自動保存をその場で書く（Android: onCleared）。
    ///
    /// 自動保存は編集が止まってから0.5秒待って書くので、編集してすぐホームへ戻ると、
    /// 書く前にアプリが止められ、そのまま終了されると最後の編集が失われる。
    /// 書いてよいかの判断はAutosavePolicy（開けない動画を落とした回の保留を守る）。
    func flushAutoSave() {
        guard autoSaveTask != nil else { return }
        autoSaveTask?.cancel()
        autoSaveTask = nil
        guard autosavePolicy.shouldSaveOnExit(canUndo: canUndo) else { return }
        performAutoSave()
    }

    /// JSONの組み立てとUserDefaultsへの書き込みをメインスレッドの外で行う。
    ///
    /// ひとことを1文字打つたびに（デバウンス後）走る処理で、クリップが100本あると
    /// エンコードだけで無視できない時間になる。@MainActorのまま実行すると、その間
    /// 入力も再生もスクロールも止まる（Android: 自動保存をDispatchers.IOへ移したのと同じ）。
    /// clipsは値型なのでスナップショットを渡すだけで安全に切り離せる。
    ///
    /// 書き込み先は`autoSaveQueue`（直列）。並列に投げると新旧が入れ替わりうる（理由は同キューのコメント）。
    private func performAutoSave() {
        let snapshot = clips
        let index    = selectedIndex
        let key      = autoSaveKey
        // selfをクロージャへ持ち込まないよう、保存先も先にローカルへ取り出しておく
        let store    = SendableDefaults(defaults: defaults)
        autoSaveQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            store.defaults.set(data,  forKey: key + "_clips")
            store.defaults.set(index, forKey: key + "_index")
        }
    }

    /// 前回の続き（自動保存）を復元する。VlogStore.swift本体のinit()から呼ぶためinternal。
    ///
    /// **同期で行うのが要点。** 以前は`Task { await restoreAutoSave() }`と非同期にしていたため、
    /// initが返ってから復元が実際に走るまでの間、ユーザーが操作できる窓があった。
    /// その隙に動画を追加していると、あとから来た`clips = loaded`がそれを丸ごと上書きし、
    /// さらに`clearHistory()`で「もとに戻す」手段まで消してしまう。
    /// initが返った時点で復元が済んでいれば、そういう瞬間がそもそも存在しない。
    ///
    /// 中身はUserDefaultsの読み出しとファイルの存在確認だけなので、同期でも起動は止まらない
    /// （PHAssetの確認は件数ぶん往復せず1回にまとめてある。`validClips`参照）。
    /// 唯一重い「撮影時刻の取り直し」は非同期のまま、init側から別に呼んでいる。
    ///
    /// - Returns: 開けない・壊れていて落とした動画の本数（自動保存を保留するかの判断に使う。AutosavePolicy）
    @discardableResult
    func restoreAutoSave() -> Int {
        // 1件ずつ読む。配列ごと読んでいた頃は、1件壊れているだけで前回の続きが丸ごと復元されず、
        // 次の自動保存で空の一覧が書き戻されて消えていた（LossyList）
        guard let data   = defaults.data(forKey: autoSaveKey + "_clips"),
              let saved  = try? JSONDecoder().decode(LossyList<VlogClip>.self, from: data) else { return 0 }
        let savedIndex   = defaults.object(forKey: autoSaveKey + "_index") as? Int

        let (loaded, unreadable) = validClips(from: saved.elements)
        let excluded = unreadable + saved.droppedCount
        clips = loaded
        if let si = savedIndex, loaded.indices.contains(si) { selectedIndex = si }
        else if !loaded.isEmpty { selectedIndex = 0 }

        // 復元直後を「起点」にする。ここで履歴を消しておかないと、アプリを開いた直後に
        // 「もとに戻す」を押せてしまい、空の状態へ戻ってしまう（Android: clearHistory）
        clearHistory()

        if excluded > 0 {
            showMessage(Formatters.restoreDroppedMessage(dropped: excluded))
        }
        return excluded
    }

    /// 各クリップの参照先（ファイル存在／PHAsset存在）を検証し、無効なものを除外する。
    /// restoreAutoSave/loadProjectの両方から使う（Android: ClipStoreのreadableチェックと同じ役割）。
    /// 以前はloadProjectだけこの検証を通らず、動画を削除・移動した後に古い名前付き保存を
    /// 読み込むと無効な参照を含んだまま復元されてしまっていた。
    private func validClips(from source: [VlogClip]) -> (clips: [VlogClip], excludedCount: Int) {
        // 判定は書き出し前の確認と同じ（ClipAvailability）。フォトライブラリはまとめて1回で引く
        let existingAssetIds = ClipAvailability.existingAssetIdentifiers(
            among: source.compactMap { $0.assetIdentifier }
        )

        var loaded: [VlogClip] = []
        var excluded = 0
        for var clip in source {
            guard ClipAvailability.isAvailable(clip, existingAssets: existingAssetIds) else {
                excluded += 1
                continue
            }
            // ファイル取り込みは、見つかった場所を持たせ直す（古い保存データは絶対パスしか持っていない）
            if let resolved = clip.resolvedFileURL, FileManager.default.fileExists(atPath: resolved.path) {
                if clip.relativeFilePath == nil {
                    clip.relativeFilePath = resolved.lastPathComponent
                }
                clip.fileURL = resolved
            }
            loaded.append(clip)
        }
        return (loaded, excluded)
    }

    /// タイムラインの全クリップについて、動画が今も開けるかを確かめ直す（Android: refreshMissingClips）。
    /// アプリが前面に戻ったとき・再生できなかったとき・書き出しが終わったときに呼ぶ。
    /// 判定は復元と同じ（ClipAvailability）で、フォトライブラリはまとめて1回で引くので軽い。
    func refreshMissingClips() {
        let missing = Set(ClipAvailability.unavailableIndices(in: clips).map { clips[$0].id })
        if missing != missingClipIds { missingClipIds = missing }
    }

    // MARK: - 使われなくなった取り込みファイル

    /// ファイルから取り込んだ動画のコピー（Documents内の`UUID_元の名前`）のうち、タイムラインにも
    /// 一時保存にも使われていないものを消す（Android: releaseUnreferencedPermissions と同じ役割）。
    ///
    /// ファイルから取り込むときは動画をDocumentsへコピーする。クリップを削除しても、
    /// 「もとに戻す」で戻せるようにコピーはその場では消さないので、消さないまま使い続けると
    /// タイムラインにも一時保存にも現れない動画がストレージを占め続けていた。
    /// 起動直後（履歴は空で、もとに戻す先が無い）に、参照されていないものだけを消す。
    ///
    /// 開けない動画を落として復元した回は呼ばない（自動保存を保留するのと同じ理由。AutosavePolicy）。
    /// 一覧はこの場で（メインスレッドで）取るので、このあと始まった取り込みのコピーを消すことはない。
    /// 消すのは`UUID_`で始まる名前だけ（取り込み以外で置かれたファイルには触らない）。
    func releaseUnreferencedImportedFiles() {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: documents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else { return }

        let referenced = Set(
            (clips + savedProjects.flatMap(\.clips)).compactMap { clip in
                clip.relativeFilePath ?? clip.fileURL?.lastPathComponent
            }
        )
        let unused = entries.filter { url in
            Self.isImportedCopyName(url.lastPathComponent) && !referenced.contains(url.lastPathComponent)
        }
        guard !unused.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in unused { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// 取り込みでコピーしたファイルの名前か（`UUID_元の名前`。ContentView+Import.makeClipFromURL）
    nonisolated static func isImportedCopyName(_ name: String) -> Bool {
        let parts = name.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return false }
        return UUID(uuidString: String(parts[0])) != nil
    }

    // MARK: - 撮影時刻の取り直し

    /// 撮影時刻を確かな手がかりから取れていないクリップ（`shotAtReliable`がfalse）の時刻を
    /// 動画から取り直す。復元時と一時保存の読み出し時に呼ぶ（Android: refreshUnreliableShotTimes）。
    ///
    /// 撮影時刻は動画ファイルから決まる値で、ユーザーが編集するものではない。それなのに追加した
    /// 時点の値をそのまま保存し続けると、その時に手がかりが足りず取り込み時刻で代用した値が、
    /// 同じ動画を追加し直しても「追加済み」でスキップされるため、消して追加し直すまで残ってしまう。
    ///
    /// 取り直しても確かな値が取れなければ、いまの値のままにして`shotAtRefreshed`を立て、以後は
    /// 試さない（手がかりが何も無い動画を毎起動読み直すのを避けるため）。
    /// 並び順は変えず（ユーザーが並べ替えた順序を壊さないため）、undo履歴にも積まない（編集ではない）。
    func refreshUnreliableShotTimes() async {
        let targets = clips.filter { !$0.shotAtReliable && !$0.shotAtRefreshed }
        guard !targets.isEmpty else { return }

        let now = Date()
        var refreshed: [UUID: VideoMeta] = [:]
        for clip in targets {
            // 取り直しの基準時刻は、いま持っている撮影時刻（無ければ現在時刻）。
            // 手がかりが見つからなかったときに値が動いてしまわないようにする
            let fallback = clip.shotAtMillis > 0
                ? Date(timeIntervalSince1970: Double(clip.shotAtMillis) / 1000)
                : now
            if let meta = await VideoMetadataReader.read(for: clip, fallbackDate: fallback) {
                refreshed[clip.id] = meta
            }
        }
        guard !refreshed.isEmpty else { return }
        applyRefreshedShotTimes(refreshed)
    }

    /// 撮影時刻を取り直した結果を反映する。並び順は変えず、履歴にも積まない（編集ではない）。
    ///
    /// 履歴に積んである過去の状態にも同じ結果を当てる。撮影時刻は動画ファイルから決まる値で、
    /// 編集の一部ではないため。当てないと、取り直し（起動直後に裏で1本ずつ読む）の最中に
    /// 編集してから「もとに戻す」を押したとき、時刻が取り直し前の値へ戻ってしまう
    /// （印も外れるので、次の起動でまた読み直すことにもなる。Android: TimelineStore.applyRefreshedShotTimes）。
    /// 履歴のスナップショットにも同じクリップ（同じid）が入っているので、idで突き合わせれば当てられる。
    ///
    /// - Parameter refreshed: クリップidごとの取り直し結果。対象でなかったクリップ（この間に
    ///   追加されたものなど）は触らない
    func applyRefreshedShotTimes(_ refreshed: [UUID: VideoMeta]) {
        func apply(_ list: [VlogClip]) -> [VlogClip] {
            list.map { clip in
                guard let meta = refreshed[clip.id] else { return clip }
                var updated = clip
                updated.shotAtRefreshed = true
                // 確かな値が取れなければ、値はそのままに「試した」印だけ付ける
                guard meta.shotAtReliable else { return updated }
                updated.timeText       = meta.timeText
                updated.dateText       = meta.dateText
                updated.shotAtMillis   = meta.shotAtMillis
                updated.shotAtReliable = true
                return updated
            }
        }
        clips = apply(clips)
        updateHistory(apply)
        scheduleAutoSave()
    }

    // MARK: - Named saves

    /// 動画を読み込み中は、一時保存の保存・上書き・読み出しをしない
    /// （Android: ProjectsController.refuseWhileAdding）。
    ///
    /// 読み込み中のタイムラインは途中の状態で、保存すると一部だけが残り、読み出すと
    /// あとから読み込み終えた動画が読み出した内容に混ざってしまうため。
    /// - Returns: 読み込み中で断った場合はtrue（通知済み）
    private func refuseWhileImporting() -> Bool {
        guard isImporting else { return false }
        showMessage("動画を読み込み中です。終わってからもう一度お試しください")
        return true
    }

    /// いまの編集内容に名前を付けて残す。結果（保存した名前・断った理由）はトーストで知らせる
    /// （Android: ProjectsController.save）。
    /// - Parameter name: 空（空白だけ）なら保存した日時「M/d HH:mm」を名前にする
    /// - Returns: 実際に保存した名前（同名があれば連番が付いた名前）。保存しなかった場合はnil
    @discardableResult
    func saveCurrentProject(name: String) -> String? {
        guard !refuseWhileImporting() else { return nil }
        guard !clips.isEmpty else {
            showMessage("保存できる編集内容がありません")
            return nil
        }
        guard savedProjects.count < VlogLayout.maxSavedProjects else {
            showMessage("保存は\(VlogLayout.maxSavedProjects)件までです。不要なものを削除してください")
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty
            ? Formatters.savedAtLabel(msSinceEpoch: Int64(Date().timeIntervalSince1970 * 1000))
            : trimmed

        // 同名がすでにあれば連番を付ける。以前はダイアログを開いたときの既定値しか
        // 重複を見ておらず、自分で打った名前は同名のまま並んでいた（Android: uniqueSaveName）
        let savedName = Formatters.uniqueSaveName(
            base: label, existingNames: Set(savedProjects.map { $0.name })
        )
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        savedProjects.insert(
            makeSavedProject(id: nextProjectId(now: now), name: savedName, savedAt: now), at: 0
        )
        persistSavedProjects()
        showMessage("「\(savedName)」を保存しました")
        return savedName
    }

    /// 一時保存のid。基本は保存した時刻だが、同じミリ秒の中で2件保存されると衝突する。
    ///
    /// idは読み出し・上書き・削除の対象を指す唯一の手がかりなので、重複すると
    /// `deleteSavedProject`の`removeAll`が**両方消す**（消したつもりのない保存が消える）。
    /// 既存と重ならないところまでずらして、その形を作らせない（Android: nextProjectId）。
    private func nextProjectId(now: Int64) -> Int64 {
        let taken = Set(savedProjects.map { $0.id })
        var candidate = now
        while taken.contains(candidate) { candidate += 1 }
        return candidate
    }

    func loadProject(_ project: SavedProject) {
        guard !refuseWhileImporting() else { return }
        let (loaded, unreadable) = validClips(from: project.clips)
        // 保存データの中で壊れていたクリップも「見つからなかった」に数える（Android: readableClips）
        let excluded = unreadable + project.droppedClipCount

        // 保存内の動画が1本も読めないのに置き換えると、作業中のタイムラインが空になってしまう。
        // その場合は置き換えずに理由だけ知らせる（Android: canReplaceWithProject）
        guard Formatters.canReplaceWithProject(loaded: loaded.count, dropped: excluded) else {
            showMessage(Formatters.projectUnreadableMessage(dropped: excluded))
            return
        }

        mutateClips {
            clips         = loaded
            selectedIndex = loaded.isEmpty ? nil : 0
        }
        releaseUnusedMediaCaches()
        showMessage(Formatters.projectLoadedMessage(dropped: excluded))
        // 読み出したあとは、撮影時刻が確かでないクリップを取り直す（復元時と同じ扱い）
        Task { await refreshUnreliableShotTimes() }
    }

    /// 既存の保存を、名前とidはそのままに現在の編集内容で上書きする（Android: overwriteProject）。
    /// 上書きされた保存の中身は「もとに戻す」では戻せないので、呼び出し側で確認を挟むこと
    func overwriteProject(id: Int64, name: String) {
        guard !refuseWhileImporting() else { return }
        // 空のタイムラインで上書きすると、保存の中身が消えるだけになる
        guard !clips.isEmpty else {
            showMessage("保存できる編集内容がありません")
            return
        }
        guard let idx = savedProjects.firstIndex(where: { $0.id == id }) else {
            showMessage("この保存は上書きできませんでした")
            return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        savedProjects[idx] = makeSavedProject(id: id, name: name, savedAt: now)
        persistSavedProjects()
        showMessage("「\(name)」に上書きしました")
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
        defaults.set(data, forKey: savedProjectsKey)
    }

    /// VlogStore.swift本体のinit()から呼ぶためinternal
    func loadSavedProjectsFromDefaults() {
        // 1件ずつ読む。配列ごと読んでいた頃は、1件壊れているだけで一覧が空に見え、次に保存したとき
        // 残りの全件が上書きされて消えていた（LossyList。Android: readProjects）
        guard let data     = defaults.data(forKey: savedProjectsKey),
              let projects = try? JSONDecoder().decode(LossyList<SavedProject>.self, from: data) else { return }
        savedProjects = projects.elements.sorted { $0.savedAt > $1.savedAt }
    }
}
