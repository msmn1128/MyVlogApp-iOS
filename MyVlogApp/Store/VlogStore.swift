import SwiftUI
import Combine
import Photos

// MARK: - VlogStore
//
// undo/redo履歴管理はVlogStore+History.swiftへ、自動保存・名前付き保存の永続化は
// VlogStore+Persistence.swiftへ切り出してある（Android: ClipStoreの分離と同じ考え方）。
// stored propertyはSwiftの制約上extensionへ置けないため、このファイルの型定義本体に残し、
// 各extensionのメソッドから参照できるようprivateを外してある
// （ContentView.swiftのphotoItems等、他のextension分割と同じ方式）。

/// Observationを使う理由は VideoPlayerManager のコメントを参照
@MainActor
@Observable
final class VlogStore {
    // MARK: Published state
    var clips: [VlogClip] = []
    var selectedIndex: Int? = nil
    var isContinuousPlay: Bool
    var savedProjects: [SavedProject] = []
    /// 一時的な通知メッセージ（Android: VlogEvent.Message / Toast相当）
    var toastMessage: String? = nil
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// タイムライン全体のミュート。クリップ個別の`isMuted`とは独立していて、
    /// こちらがonの間はどのクリップも音声が出ない（Android: VlogViewModel.timelineMuted）
    var timelineMuted: Bool
    /// 動画を読み込み中（メタデータを読んでいる間）か。オーバーレイの表示に加えて、
    /// 一時保存の保存・読み出しを断る判断にも使う（Android: VlogViewModel.isAdding）。
    /// 以前はContentViewの@Stateだったため、SavedProjectsViewからは見えなかった。
    var isImporting: Bool = false

    // MARK: Undo / Redo（実体の操作はVlogStore+History.swift）
    var undoStack: [UndoEntry] = []
    var redoStack: [UndoEntry] = []
    let maxUndo = 50
    /// 直前に積んだ編集のタグと、その時刻。まとめ判定に使う（VlogStore+History.swift）。
    ///
    /// Android（EditHistory）と同じく「直前の1件」だけを覚える。タグごとに最終時刻を
    /// 辞書で持つと、別の操作を挟んでも同じタグならまとまってしまい、履歴が1件消える。
    var lastTag: String? = nil
    var lastTagAt: TimeInterval = 0

    // MARK: Persistence（実体の操作はVlogStore+Persistence.swift）
    @ObservationIgnored var autoSaveTask: Task<Void, Never>?
    /// 前回の続きをいつ書き換えてよいか（AutosavePolicy.swift）
    @ObservationIgnored var autosavePolicy = AutosavePolicy()
    let autoSaveKey      = "vlog_autosave_v1"
    let savedProjectsKey = "vlog_saved_projects_v1"
    // init内（全stored propertyの初期化が済む前）から読むため、インスタンスではなく型に持たせる
    private static let continuousPlayKey = "vlog_continuous_play"
    /// 以前はタイムライン全体のミュートを保存していた。いまは引き継がないので、残っていれば消すだけ
    private static let legacyTimelineMutedKey = "vlog_timeline_muted"

    /// 保存先。アプリでは常に`.standard`で、差し替えるのはテストだけ。
    ///
    /// 単体テストが`.standard`を使うと、テストホスト（＝アプリ本体）の実際の保存データを
    /// 読み書きしてしまい、テスト同士が順番に依存するうえシミュレータ上の編集内容も壊す。
    /// テストは`UserDefaults(suiteName:)`で作った使い捨ての領域を渡す。
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults    = defaults
        // 連続再生の既定はオン（Android: ClipStore.restoreAutoAdvance の既定 true）。
        // bool(forKey:)は未保存でfalseを返すため、初めて開いた人は連続再生オフで始まっていた
        isContinuousPlay = defaults.object(forKey: Self.continuousPlayKey) as? Bool ?? true
        // タイムライン全体のミュートは次回起動へ引き継がない（Android: 起動時の引き継ぎはしない）。
        // 引き継ぐと、前回ミュートにしたことを忘れたまま書き出して、無音の動画ができてしまう
        timelineMuted    = false
        defaults.removeObject(forKey: Self.legacyTimelineMutedKey)
        loadSavedProjectsFromDefaults()
        // 前回の続きの復元は同期で済ませる。非同期（Task）にすると、復元が走る前に
        // ユーザーが操作できてしまう窓ができ、その間に追加した動画を
        // あとから来た復元が丸ごと上書きしてしまう（詳しくはrestoreAutoSaveのコメント）
        let dropped = restoreAutoSave()
        autosavePolicy.onRestored(droppedCount: dropped)
        // 開けない動画を落とした回は消さない。落とした動画のコピーも「使われていない」と判断されてしまう。
        // 保存先がアプリ本来の領域（.standard）のときだけ行う。テストやUIテストの使い捨ての領域から
        // 判断すると、アプリ本来の編集内容が使っているコピーまで「使われていない」に見えて消してしまう
        if dropped == 0, defaults === UserDefaults.standard { releaseUnreferencedImportedFiles() }
        // 撮影時刻の取り直しだけは動画を開くので非同期。こちらは並び順も編集内容も
        // 変えず、いま並んでいるクリップに後から値を足すだけなので競合しない
        Task { await refreshUnreliableShotTimes() }
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

    /// clips配列そのものを触る操作（追加・削除・並べ替え・ミュート）の定型。
    /// VlogStore+Persistence.swiftのloadProjectからも呼ぶためinternal。
    func mutateClips(tag: String? = nil, _ body: () -> Void) {
        recordForUndo(tag: tag)
        body()
        scheduleAutoSave()
    }

    // MARK: - Clip operations

    /// `addClips`が追加を断った件数（呼び出し側が理由ごとの通知文を組み立てるのに使う。
    /// Android: TimelineStore.InsertResult）
    struct AddResult {
        /// すでにタイムラインにあったため入れなかった件数
        var alreadyPresent: Int = 0
        /// 上限（`VlogLayout.maxClips`）を超えるため入れなかった件数
        var overLimit: Int = 0
        /// タイムラインへ入れなかったクリップそのもの。ファイル取り込みは先にDocumentsへ
        /// コピーしてしまっているので、呼び出し側がそのコピーを消せるように返す
        /// （消さないと、追加もされていない動画の実体がストレージに残り続ける）
        var rejected: [VlogClip] = []
    }

    /// 撮影/作成日時順になる位置へ追加し、追加した中で最も古いものを選択する
    /// （Android: TimelineStore.insertByShotAt / mergeByShotAt）。
    ///
    /// 入れないもの:
    ///  - すでにタイムラインにある動画。フォトライブラリ由来は識別子（`assetIdentifier`）で、
    ///    ファイル取り込みは中身の指紋（`contentKey`）で判定する。
    ///    ファイル取り込みは毎回Documentsへ別名でコピーするためパスが手がかりにならず、
    ///    以前は同じ動画を2回選んでも重複を検知できなかった（`FileContentKey`参照）
    ///  - 上限（`VlogLayout.maxClips`）を超える分
    @discardableResult
    func addClips(_ newClips: [VlogClip]) -> AddResult {
        guard !newClips.isEmpty else { return AddResult() }

        // 今回追加するぶんも見ていく中で足していく。そうしないと、1回の操作で同じ動画を
        // 2つ選んだとき（タイムラインにはまだ無いので）どちらも「新規」として入ってしまう
        var seenAssets  = Set(clips.compactMap { $0.assetIdentifier })
        var seenContent = Set(clips.compactMap { $0.contentKey })
        let (fresh, duplicates) = newClips.reduce(into: ([VlogClip](), [VlogClip]())) { acc, clip in
            if let id = clip.assetIdentifier {
                if seenAssets.contains(id) { acc.1.append(clip); return }
                seenAssets.insert(id)
            } else if let key = clip.contentKey {
                if seenContent.contains(key) { acc.1.append(clip); return }
                seenContent.insert(key)
            }
            acc.0.append(clip)
        }
        let room     = max(0, VlogLayout.maxClips - clips.count)
        let toInsert = Array(fresh.prefix(room))
        let result   = AddResult(
            alreadyPresent: duplicates.count,
            overLimit:      fresh.count - toInsert.count,
            rejected:       duplicates + fresh.dropFirst(toInsert.count)
        )
        guard !toInsert.isEmpty else { return result }

        let oldestAddedId = toInsert.min { $0.sortKeyMs < $1.sortKeyMs }?.id

        mutateClips {
            var merged = clips
            for clip in toInsert.sorted(by: { $0.sortKeyMs < $1.sortKeyMs }) {
                let index = merged.firstIndex { $0.sortKeyMs > clip.sortKeyMs } ?? merged.count
                merged.insert(clip, at: index)
            }
            clips = merged

            if let id = oldestAddedId, let index = clips.firstIndex(where: { $0.id == id }) {
                selectedIndex = index
            }
        }
        return result
    }

    func deleteClip(at index: Int) {
        guard clips.indices.contains(index) else { return }
        mutateClips {
            clips.remove(at: index)
            if clips.isEmpty {
                selectedIndex = nil
            } else if let si = selectedIndex {
                // 消した位置より後ろを選んでいたなら、選んでいたクリップ自体が1つ手前へずれる。
                // min(si, count-1)だけで済ませると、手前を消したときに選択が
                // 「別のクリップ」へ移ってしまう（今はUIから選択中のクリップしか
                // 消せないので表に出ないが、消し方を増やしたときに踏む）
                let shifted = si > index ? si - 1 : si
                selectedIndex = min(shifted, clips.count - 1)
            }
        }
        releaseUnusedMediaCaches()
    }

    func deleteAllClips() {
        mutateClips {
            clips.removeAll()
            selectedIndex = nil
        }
        releaseUnusedMediaCaches()
    }

    /// タイムラインに残っていない素材の波形・サムネイル・AVAssetをキャッシュから捨てる
    /// （Android: VlogViewModel.cancelWaveformJobIfUnused）。
    ///
    /// 捨てないままだと、もう画面に出ないクリップの波形（長い動画だと1本あたり数万バイト）と
    /// サムネイル画像、デコーダを抱えたAVAssetをアプリが終わるまで持ち続ける。
    ///
    /// 一覧を更新した「あと」に呼ぶこと。同じ動画を2回追加している場合にまだ他のクリップが
    /// 同じ素材を参照していれば、そちらの表示に使われているものを巻き添えにしないため。
    func releaseUnusedMediaCaches() {
        let inUse = Set(clips.map { $0.mediaCacheKey })
        Task.detached(priority: .utility) {
            await AssetLoader.shared.retain(only: inUse)
            await WaveformExtractor.shared.retain(only: inUse)
            await ThumbnailLoader.shared.retain(only: inUse)
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

    /// トリミング範囲の変更。
    ///
    /// 範囲が変わっていなければ何もしない。つまみを端の限界で止めたままのドラッグ、端での
    /// 自動スクロール（16msごと）、すでに同じ長さの「2s」などは同じ値で呼んでくる。ここで弾かないと
    /// 空振りの「もとに戻す」が積まれ、それを編集の合図と取り違えて、開けなかった動画の編集内容を
    /// 残すための自動保存の保留（AutosavePolicy）まで外れてしまう（Android: TimelineStore.updateTrim）
    func updateTrim(startMs: Int64, endMs: Int64) {
        guard let i = selectedIndex, let clip = selectedClip else { return }
        guard clip.startMs != startMs || clip.endMs != endMs else { return }
        updateSelected(tag: "trim:\(i)") { clip in
            clip.startMs = startMs
            clip.endMs   = endMs
        }
    }

    /// いまのトリム選択の始まりから、指定の長さだけを選び直す（操作バーの 2s / 4s。Android: applyTrimPreset）。
    ///
    /// 動画の終わりに収まらないときは、始まりを手前へずらして指定の長さを確保する
    /// （動画がそれより短いときは動画全体）。終わりで切っていた頃は、終わり近くで押すと
    /// 「2s」なのに0.5秒になるなど、知らせもなく指定より短くなっていた。
    func applyTrimPreset(lengthMs: Int64) {
        guard let clip = selectedClip, clip.durationMs > 0 else { return }
        let length  = min(lengthMs, clip.durationMs)
        let startMs = min(max(clip.startMs, 0), clip.durationMs - length)
        updateTrim(startMs: startMs, endMs: startMs + length)
    }

    /// トリミング区間を長さそのままで前後に移動する（Android: moveTrim）。
    /// ひとことの区切り（先頭は除く）も同じ分だけ一緒にずらす。
    @discardableResult
    func moveTrim(targetStartMs: Int64) -> (startMs: Int64, endMs: Int64)? {
        guard let clip = selectedClip else { return nil }
        let span = clip.trimmedDurationMs
        guard span > 0 else { return nil }

        let maxStart = max(0, clip.durationMs - span)
        // トリム範囲と区切りは同じ量だけ動かす（相対位置を保つのがこの操作の目的）。
        // 区切りが動画の範囲からはみ出すぶんは、区切りを個別に丸めるのではなく移動そのものを
        // 手前で止める（理由はclampTimelineShiftのコメント）
        let delta = clampTimelineShift(
            texts: clip.texts,
            requested: min(max(targetStartMs, 0), maxStart) - clip.startMs,
            durationMs: clip.durationMs
        )
        guard delta != 0 else { return (clip.startMs, clip.endMs) }
        let newStart = clip.startMs + delta
        let newEnd   = newStart + span

        updateSelected(tag: "trimMove:\(selectedIndex ?? -1)") { c in
            c.startMs = newStart
            c.endMs   = newEnd
            // 先頭の区間は常に絶対位置0（動画そのものの頭）なので動かさない。それ以外はすべて
            // 同じdeltaで動く。はみ出さない量まで詰めてあるので、ここで個別に丸める必要はない
            c.texts = c.texts.map { seg in
                guard seg.startMs != 0 else { return seg }
                var s = seg
                s.startMs = seg.startMs + delta
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

    /// ひとことの書き換え。文字が変わっていなければ何もしない（空振りの「もとに戻す」を積まない。
    /// 理由はupdateTrimと同じ。日本語の変換中のように、同じ文字のまま通知が来ることがある）
    func updateText(_ text: String, segmentIndex: Int) {
        guard let i = selectedIndex, let clip = selectedClip,
              clip.texts.indices.contains(segmentIndex),
              clip.texts[segmentIndex].text != text else { return }
        updateSelected(tag: "text:\(i):\(segmentIndex)") { c in
            c.texts[segmentIndex].text = text
        }
    }

    /// positionMsに区切りを入れる。入れられたら新しい区間のindexを返す。
    ///
    /// 入れられない場合は理由をトーストで知らせる（Android: TimelineStore.splitTextAtPlayhead）。
    /// 以前は黙ってnilを返していたため、押しても何も起きず理由が分からなかった。
    @discardableResult
    func splitAt(positionMs: Int64) -> Int? {
        guard let clip = selectedClip else { return nil }
        let minDist = VlogClip.splitMinDistanceMs
        guard positionMs - clip.startMs >= minDist, clip.endMs - positionMs >= minDist else {
            showMessage("区切る位置が端に寄りすぎています")
            return nil
        }
        // 先頭（絶対位置0）も含めて近すぎる区切りが無いか見る
        if clip.texts.contains(where: { abs($0.startMs - positionMs) < minDist }) {
            showMessage("すぐ近くに区切りがあります")
            return nil
        }

        // 後半は空文字にする（動画追加時の初期区間と同じ扱い）。前半の文字を複製すると
        // 分割できたのかが入力欄から分からず、「ひとこと」を入れると未入力のまま
        // 書き出したときに焼き込まれる。空なら入力欄にはグレーの案内文字が出るので
        // 未入力なのが分かり、分割自体は区間バッジと波形の区切り線で分かる
        // （Android: TimelineStore.splitTextAtPlayhead）
        let newSeg = TextSegment(startMs: positionMs)
        let insertIdx = clip.texts.firstIndex(where: { $0.startMs > positionMs }) ?? clip.texts.count
        updateSelected { c in
            c.texts.insert(newSeg, at: insertIdx)
        }
        return insertIdx
    }

    func removeSplitNear(positionMs: Int64) {
        guard let clip = selectedClip, let splitMs = clip.splitPointNear(positionMs: positionMs) else { return }
        updateSelected { c in
            // 同じstartMsの区切りが複数あっても1件だけ消す（Android: removeSplitと同じ安全策）
            if let idx = c.texts.firstIndex(where: { $0.startMs == splitMs }) {
                c.texts.remove(at: idx)
            }
        }
    }

    // MARK: - Continuous play

    // toggleContinuousPlay/toggleTimelineMutedはrecordForUndo/scheduleAutoSaveを
    // 経由しない。これはクリップのデータではなく「アプリの設定」（連続再生はUserDefaultsに
    // 直接保存、タイムライン全体のミュートはその回かぎり）だから。autosaveはclips/selectedIndexしか対象にしておらず、undo
    // スタックもクリップの編集履歴のためのものなので、意図的にどちらも通さない
    // （toggleMute(at:)はclips[index].isMutedというクリップ自身のデータなので
    // 対照的にrecordForUndo/scheduleAutoSaveの対象になる）。
    func toggleContinuousPlay() {
        isContinuousPlay.toggle()
        defaults.set(isContinuousPlay, forKey: Self.continuousPlayKey)
    }

    // MARK: - Mute

    /// 次回起動へは引き継がない（理由はinitのコメント）
    func toggleTimelineMuted() {
        timelineMuted.toggle()
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
}
