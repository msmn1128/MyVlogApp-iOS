import AVFoundation
import Combine
import SwiftUI

/// `@Observable`（Observation）を使うのが要点。`ObservableObject`だと「このオブジェクトの
/// 何かが変わった」としか伝わらず、購読しているView（ContentViewを含む8つ）が
/// **currentTimeMsの更新に合わせて毎秒30回すべて再評価**されていた。
/// Observationはbodyの中で実際に読んだプロパティだけを依存として記録するため、
/// 再生位置を読まないViewは再生中に無効化されなくなる
/// （Android版が`State<Long>`＋`derivedStateOf`で再コンポーズ範囲を絞っているのと同じ狙い）。
@MainActor
@Observable
final class VideoPlayerManager {
    @ObservationIgnored let player = AVPlayer()

    var currentTimeMs: Int64 = 0
    var isPlaying:     Bool  = false
    var isLoading:     Bool  = false

    @ObservationIgnored private(set) var trimStartMs: Int64 = 0
    @ObservationIgnored private(set) var trimEndMs:   Int64 = 0

    // nonisolated(unsafe) so deinit can access without @MainActor。
    // 以下はUIが読まない内部状態なので、Observationの追跡対象から外す
    @ObservationIgnored nonisolated(unsafe) private var periodicObserver: Any?
    @ObservationIgnored nonisolated(unsafe) private var boundaryObserver: Any?
    @ObservationIgnored private var endNoteObserver: NSObjectProtocol?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// いまの読み込みの番号。取り消された古い読み込みが、新しい読み込みの「読み込み中」を
    /// 下ろしてしまわないよう、自分が最新のときだけ下ろす（loadClip / doLoad）
    @ObservationIgnored private var loadGeneration = 0
    /// AVPlayerの再生速度の監視。電話・ほかのアプリの音・イヤホンを抜いたときなど、
    /// こちらがpause()を呼ばずに止まったときも`isPlaying`を合わせるため
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    /// 読み込んだAVPlayerItemの状態の監視。読めない動画（移動・削除された、アクセスできない）を知らせるため
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    /// 直前に再生できなかったクリップ。同じ動画で続けて失敗したときに知らせ直さないため
    /// （選んだときと再生を押したときの両方で失敗するので、そのままだと同じ知らせが続けて出る）
    @ObservationIgnored private var lastErrorClipId: UUID?

    @ObservationIgnored weak var store: VlogStore?

    @ObservationIgnored private var shouldAutoPlayNext: Bool = false

    /// トリム終端をすでに処理したAVPlayerItem。
    ///
    /// 終端の検知は boundaryObserver と AVPlayerItemDidPlayToEndTime の2経路あり、
    /// トリム終端が動画の実際の末尾と一致していると**同じ「終わり」に対して両方が相次いで
    /// 呼ばれる**。2回目まで処理すると、1回目が始めた次のクリップへの切り替えを打ち消して
    /// しまい（`stopAtTimelineEnd`が`shouldAutoPlayNext`を下ろすため、次のクリップは
    /// 頭で止まったままになる）、連続再生が1本目で終わってしまう。
    /// 同じitemの終わりは一度しか処理しない。
    @ObservationIgnored private var handledEndForItem: AVPlayerItem?

    /// 波形をドラッグしている間（トリム端／分割線／本体のどれでも）だけtrue。
    ///
    /// seek(to:)は非同期で、呼んだ直後のAVPlayerの内部時刻はまだ古い値のことがある。
    /// 33ms間隔のperiodicObserverがちょうどその隙間に当たると、なぞっている指に
    /// 追従して置いたはずのcurrentTimeMsがAVPlayer側の古い値で上書きされ、
    /// シークのピンが指の動きと無関係に後ろへ戻って見える
    /// （Android版で「ぴょんぴょん跳ねる」として直したのと同じ不具合）。
    /// ドラッグ中はperiodicObserverによる上書きだけを止め、currentTimeMsは
    /// 指の動きに合わせてseek(to:)が直接更新し続ける。
    @ObservationIgnored private(set) var isInteractiveSeeking: Bool = false

    init() {
        player.volume = 1.0
        player.isMuted = false
        let interval = CMTime(value: 1, timescale: 30)
        periodicObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            // queue: .mainで必ずメインスレッド上で呼ばれることが保証されているが、
            // このクロージャの型はSwift 6の並行性チェック上@Sendableとして扱われるため、
            // assumeIsolatedでMainActor隔離のプロパティへ安全に触れることを伝える
            // （Task { @MainActor in ... }に包むと非同期になり、ドラッグ中の
            // 上書き防止に必要な同期的な即時反映が失われてしまう）
            MainActor.assumeIsolated {
                guard let self else { return }
                guard !self.isInteractiveSeeking else { return }
                guard time.isNumeric && time.seconds.isFinite else { return }
                let ms = Int64(time.seconds * 1000)
                self.currentTimeMs = ms
            }
        }
        // 再生・一時停止は自分で`isPlaying`を立て下ろししているが、AVPlayerは割り込み
        // （電話・ほかのアプリの音・イヤホンを抜く）でも止まる。そのとき`isPlaying`がtrueのまま残り、
        // 次のタップが「一時停止」扱いになって1回空振りしていた。実際の速度に合わせ直す
        // （Android: onIsPlayingChanged）。値は通知の中ではなく、メインへ移ってから読み直す
        // （古い通知が後から届いて、いまの状態を上書きしないように）
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let playing = self.player.rate != 0
                if self.isPlaying != playing { self.isPlaying = playing }
            }
        }
    }

    deinit {
        if let obs = periodicObserver { player.removeTimeObserver(obs) }
        if let obs = boundaryObserver { player.removeTimeObserver(obs) }
        if let obs = endNoteObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Load / Reset

    func reset() {
        loadTask?.cancel()
        loadGeneration += 1
        itemStatusObservation = nil
        pause()
        removeBoundaryObserver()
        removeEndObserver()
        player.replaceCurrentItem(with: nil)
        currentTimeMs     = 0
        trimStartMs       = 0
        trimEndMs         = 0
        isLoading         = false
        handledEndForItem = nil
    }

    func loadClip(_ clip: VlogClip) {
        loadTask?.cancel()
        let autoPlay = shouldAutoPlayNext
        shouldAutoPlayNext = false
        // 連続再生で次へ進むとき以外（タイルを選んだ・削除した・もとに戻した・一時保存を読み出した）は
        // 止めてから頭を出す（Android: select → seekAndPause）。止めないと、再生中に別のタイルを
        // 選んだとき、AVPlayerの速度が残ったまま新しいクリップが勝手に流れ始めていた
        if !autoPlay { pause() }
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { await doLoad(clip, autoPlay: autoPlay, generation: generation) }
    }

    private func doLoad(_ clip: VlogClip, autoPlay: Bool, generation: Int) async {
        // 取り消された古い読み込みが、あとから始まった読み込みの表示を下ろさないようにする。
        // 以前はどの経路でも isLoading = false にしていたので、クリップを素早く切り替えると、
        // まだ読み込んでいる最中なのに「読み込み中」の表示が消えることがあった
        defer { if generation == loadGeneration { isLoading = false } }
        isLoading   = true
        trimStartMs = clip.startMs
        trimEndMs   = clip.endMs
        removeBoundaryObserver()
        removeEndObserver()

        do {
            #if DEBUG
            // UIテストで「読み込み中に再生を押す」を確実に起こすため、読み込みを遅らせる（UITestSupport）
            if let delay = UITestSupport.previewLoadDelaySeconds {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            #endif
            let asset = try await AssetLoader.shared.load(clip: clip, forPreview: true)
            guard !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: asset)
            observeFailure(of: item, clip: clip)
            player.replaceCurrentItem(with: item)
            applyMuteState(for: clip)
            seek(to: clip.startMs)
            installBoundaryObserver(endMs: clip.endMs)
            installEndObserver()
            if autoPlay {
                play()
            }
        } catch {
            // フォトライブラリに見つからない・アクセスできない動画はここへ来る。
            // 読み込み中に再生を押されていても果たせないので止める（「再生中」のまま残すと次のタップが空振りする）
            if !Task.isCancelled {
                pause()
                reportPlaybackError(clip: clip)
            }
        }
    }

    // MARK: - 再生できない動画

    /// 読み込んだ動画が再生できないと分かったら知らせる（ファイルは開けても中身が読めない場合など）
    private func observeFailure(of item: AVPlayerItem, clip: VlogClip) {
        itemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch status {
                case .failed:      self.reportPlaybackError(clip: clip)
                // 読み込めたら、次に同じ動画で失敗したときはまた知らせる
                case .readyToPlay: if self.lastErrorClipId == clip.id { self.lastErrorClipId = nil }
                default:           break
                }
            }
        }
    }

    /// 再生できなかったことを知らせ、開けない動画の目印を更新する（Android: onPlayerError）。
    /// 以前は開発用のログに出すだけで、プレビューが黒いまま何も起きず、理由が分からなかった
    private func reportPlaybackError(clip: VlogClip) {
        guard lastErrorClipId != clip.id else { return }
        lastErrorClipId = clip.id
        isLoading = false
        store?.showMessage("この動画を再生できませんでした（移動・削除されたか、アクセス権限が取り消されています）")
        store?.refreshMissingClips()
    }

    // MARK: - 選択・編集に合わせた頭出し

    /// タイルを選んだとき（Android: select）。止めて、そのクリップの頭（トリム開始）を出す。
    ///
    /// 選び直したのが同じクリップのときも頭へ戻す。別のクリップなら、選択の変化を見ている
    /// ContentViewがloadClipを呼び、そちらで止めて頭を出す。
    func select(index: Int) {
        guard let store, store.clips.indices.contains(index) else { return }
        let sameClip = store.selectedIndex == index
        pause()
        // 同じ動画を選び直したら、失敗の知らせももう一度出してよい（再生できないまま気付けないので）
        lastErrorClipId = nil
        store.selectedIndex = index
        if sameClip { seek(to: store.clips[index].startMs) }
    }

    /// もとに戻す・やり直す・トリムのプリセットのあと（Android: applySnapshot / updateTrim）。
    /// 止めて、選択中のクリップの頭（トリム開始）を出す。再生したまま範囲や中身が変わると、
    /// どこが変わったのか画面から確かめられないため
    func showSelectedClipStart() {
        pause()
        guard let clip = store?.selectedClip else { return }
        seek(to: clip.startMs)
    }

    // MARK: - Mute

    /// クリップ個別のミュートとタイムライン全体のミュートを合わせて音量に反映する
    /// （Android: VlogViewModel.updatePlayerVolume相当）
    func applyMuteState(for clip: VlogClip?) {
        let clipMuted = clip?.isMuted ?? false
        player.volume = (store?.timelineMuted ?? false) || clipMuted ? 0 : 1
    }

    // MARK: - Playback controls

    func play()               { player.play(); isPlaying = true }
    func pause()              { player.pause(); isPlaying = false }

    /// 再生／一時停止の切り替え（プレビューのタップ）。
    ///
    /// クリップの終わりで止まっているときは、そのまま再生してもトリム終端の監視
    /// （boundaryObserver）が直ちにまた止めてしまい「ボタンが効かない」ように見える。
    /// playFromWhereに従って頭出ししてから再生する（Android: togglePlayback）。
    func togglePlayPause() {
        if isPlaying { pause(); return }

        guard let store, let index = store.selectedIndex,
              store.clips.indices.contains(index) else { play(); return }
        let clip = store.clips[index]

        switch playFromWhere(
            isLastClip: index == store.clips.count - 1,
            isContinuousPlay: store.isContinuousPlay,
            positionMs: currentTimeMs,
            clipEndMs: clip.endMs
        ) {
        case .currentPosition:
            break
        case .timelineStart:
            // 先頭クリップへ移す。選択が変わればContentViewのonChangeがloadClipを呼ぶので、
            // そちらで自動再生させる（ここでplay()しても差し替え前のitemに効いてしまう）
            shouldAutoPlayNext = true
            store.selectedIndex = 0
            if index == 0, let first = store.clips.first {
                // 既に先頭を選択中（クリップが1本だけ等）はonChangeが発火しないので直接頭出しする
                shouldAutoPlayNext = false
                seek(to: first.startMs)
                play()
            }
            return
        case .selectedClipStart:
            seek(to: clip.startMs)
        }
        play()
    }

    func seek(to ms: Int64) {
        guard ms >= 0 else { return }
        let t = CMTime(value: ms, timescale: 1000)
        // ドラッグ中はキーフレーム近傍への近似シークにして、毎フレームのseekによる
        // カクつきを減らす（既定の.zero＝正確なシークだと1回ごとに正確な位置まで
        // デコードし直すため重い）。指を離したらendInteractiveSeek()で正確に合わせ直す
        let tolerance = isInteractiveSeeking ? CMTime(value: 1, timescale: 10) : .zero
        player.seek(to: t, toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTimeMs = ms

        // 終端より手前へ戻ったら、同じクリップでもまた終端を処理できるようにする
        // （もう一度再生して終わりまで来たときに、止まらず流れ続けてしまうのを防ぐ）
        if ms < trimEndMs - playAtEndToleranceMs { handledEndForItem = nil }
    }

    /// 波形ドラッグの開始時に呼ぶ。シークを近似にし、周期観測での上書きを止める
    func beginInteractiveSeek() {
        isInteractiveSeeking = true
    }

    /// 波形ドラッグの終了時に呼ぶ。シークを正確な設定へ戻し、最後に一度だけ合わせ直す
    func endInteractiveSeek() {
        isInteractiveSeeking = false
        seek(to: currentTimeMs)
    }

    /// トリム範囲が変わったことを再生側へ反映する。
    ///
    /// 波形のドラッグだけでなく、トリムプリセット（2s/4s）ともとに戻す・やり直しからも
    /// 呼ばれる（ContentViewがselectedClip.trimBoundsのonChangeで中継する）。
    /// ここを通さないと終端の監視（boundaryObserver）が古い位置のまま残り、
    /// 「2sにしたのに最後まで再生される」ことになる。
    func updateTrimBounds(startMs: Int64, endMs: Int64) {
        // 同じ範囲で呼ばれたら何もしない。波形のドラッグ中は操作側とonChange側の
        // 両方から同じ値で届くため、ここで弾かないと監視の付け外しが二重に走る
        guard startMs != trimStartMs || endMs != trimEndMs else { return }
        trimStartMs = startMs
        trimEndMs   = endMs
        installBoundaryObserver(endMs: endMs)

        // 新しい範囲の外に取り残された再生位置を引き戻す。
        // range外のままだと波形の再生ヘッドが消え（drawPlayheadがトリム範囲内しか描かない）、
        // 今どこを見ているのか分からなくなる
        let clamped = min(max(currentTimeMs, startMs), endMs)
        if clamped != currentTimeMs { seek(to: clamped) }
    }

    // MARK: - Observers

    /// トリム終端の監視を張り直す。
    /// 呼ぶ前に必ず古い監視を外す（外し忘れると、クリップの読み込み中に
    /// トリムが変わったときなどに監視が二重に残り、終端処理が余計に走る）
    private func installBoundaryObserver(endMs: Int64) {
        removeBoundaryObserver()
        let t = CMTime(value: endMs, timescale: 1000)
        let obs = player.addBoundaryTimeObserver(forTimes: [NSValue(time: t)], queue: .main) { [weak self] in
            Task { @MainActor [weak self] in self?.handleTrimEnd() }
        }
        boundaryObserver = obs
    }

    private func removeBoundaryObserver() {
        if let obs = boundaryObserver {
            player.removeTimeObserver(obs)
            boundaryObserver = nil
        }
    }

    private func installEndObserver() {
        guard let currentItem = player.currentItem else { return }
        endNoteObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object:  currentItem,
            queue:   .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleTrimEnd() }
        }
    }

    private func removeEndObserver() {
        if let obs = endNoteObserver {
            NotificationCenter.default.removeObserver(obs)
            endNoteObserver = nil
        }
    }

    // MARK: - Trim-end handling

    private func handleTrimEnd() {
        // 同じitemの「終わり」を2回処理しない（handledEndForItemのコメント参照）
        guard let item = player.currentItem, handledEndForItem !== item else { return }
        handledEndForItem = item

        guard let store else { pause(); return }
        if store.isContinuousPlay {
            advanceToNext(store: store)
        } else {
            pause()
            seek(to: trimEndMs)
        }
    }

    private func advanceToNext(store: VlogStore) {
        guard let cur = store.selectedIndex, !store.clips.isEmpty else { return }
        if cur + 1 < store.clips.count {
            shouldAutoPlayNext = true
            store.selectedIndex = cur + 1
        } else {
            stopAtTimelineEnd(store: store)
        }
    }

    /// 最後のクリップの再生が終わったところで止める（先頭のクリップへは戻らない）。
    /// 最後のコマを出したままにする（Android: stopAtTimelineEnd）。
    ///
    /// 以前は先頭へ戻して一時停止していたが、Android版が「そこで止める」へ変わったので揃えた。
    ///
    /// 終端の検知はboundaryObserverとAVPlayerItemDidPlayToEndTimeの2経路あり、どちらからも
    /// 呼ばれうる。既にそこで止まっていれば何もしないことで、二重の呼び出しがあっても
    /// 無駄なシークを起こさない。「そこで止まっている」の判定にplayAtEndToleranceMsの幅を
    /// 持たせているのは、止めた位置が必ずしもendMsちょうどにならないため。
    private func stopAtTimelineEnd(store: VlogStore) {
        shouldAutoPlayNext = false
        // ここへ来るのは最後のクリップを再生し終えたときだけなので、選択位置は既に末尾にある
        // （advanceToNextがcur+1 >= countのときだけ呼ぶ）。念のため末尾以外なら位置だけ合わせる
        guard let last = store.clips.last, store.selectedIndex == store.clips.count - 1 else {
            pause()
            return
        }

        if !isPlaying, currentTimeMs >= last.endMs - playAtEndToleranceMs { return }

        pause()
        seek(to: last.endMs)
    }
}

// MARK: - AVPlayerLayer UIViewRepresentable

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player       = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor          = .black
        return v
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
