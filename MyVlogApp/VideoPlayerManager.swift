import AVFoundation
import Combine
import SwiftUI

@MainActor
class VideoPlayerManager: ObservableObject {
    let player = AVPlayer()

    @Published var currentTimeMs: Int64 = 0
    @Published var isPlaying:     Bool  = false
    @Published var isLoading:     Bool  = false

    private(set) var trimStartMs: Int64 = 0
    private(set) var trimEndMs:   Int64 = 0

    // nonisolated(unsafe) so deinit can access without @MainActor
    nonisolated(unsafe) private var periodicObserver: Any?
    nonisolated(unsafe) private var boundaryObserver: Any?
    private var endNoteObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?

    weak var store: VlogStore?

    private var shouldAutoPlayNext: Bool = false

    /// 波形をドラッグしている間（トリム端／分割線／本体のどれでも）だけtrue。
    ///
    /// seek(to:)は非同期で、呼んだ直後のAVPlayerの内部時刻はまだ古い値のことがある。
    /// 33ms間隔のperiodicObserverがちょうどその隙間に当たると、なぞっている指に
    /// 追従して置いたはずのcurrentTimeMsがAVPlayer側の古い値で上書きされ、
    /// シークのピンが指の動きと無関係に後ろへ戻って見える
    /// （Android版で「ぴょんぴょん跳ねる」として直したのと同じ不具合）。
    /// ドラッグ中はperiodicObserverによる上書きだけを止め、currentTimeMsは
    /// 指の動きに合わせてseek(to:)が直接更新し続ける。
    private(set) var isInteractiveSeeking: Bool = false

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
    }

    deinit {
        if let obs = periodicObserver { player.removeTimeObserver(obs) }
        if let obs = boundaryObserver { player.removeTimeObserver(obs) }
        if let obs = endNoteObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Load / Reset

    func reset() {
        loadTask?.cancel()
        pause()
        removeBoundaryObserver()
        removeEndObserver()
        player.replaceCurrentItem(with: nil)
        currentTimeMs = 0
        trimStartMs   = 0
        trimEndMs     = 0
        isLoading     = false
    }

    func loadClip(_ clip: VlogClip) {
        loadTask?.cancel()
        let autoPlay = shouldAutoPlayNext
        shouldAutoPlayNext = false
        loadTask = Task { await doLoad(clip, autoPlay: autoPlay) }
    }

    private func doLoad(_ clip: VlogClip, autoPlay: Bool) async {
        isLoading   = true
        trimStartMs = clip.startMs
        trimEndMs   = clip.endMs
        removeBoundaryObserver()
        removeEndObserver()

        do {
            let asset = try await AssetLoader.shared.load(clip: clip, forPreview: true)
            guard !Task.isCancelled else { isLoading = false; return }
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            applyMuteState(for: clip)
            seek(to: clip.startMs)
            installBoundaryObserver(endMs: clip.endMs)
            installEndObserver()
            if autoPlay {
                play()
            }
        } catch {
            print("[VideoPlayerManager] \(error)")
        }
        isLoading = false
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
    func togglePlayPause()    { isPlaying ? pause() : play() }

    func seek(to ms: Int64) {
        guard ms >= 0 else { return }
        let t = CMTime(value: ms, timescale: 1000)
        // ドラッグ中はキーフレーム近傍への近似シークにして、毎フレームのseekによる
        // カクつきを減らす（既定の.zero＝正確なシークだと1回ごとに正確な位置まで
        // デコードし直すため重い）。指を離したらendInteractiveSeek()で正確に合わせ直す
        let tolerance = isInteractiveSeeking ? CMTime(value: 1, timescale: 10) : .zero
        player.seek(to: t, toleranceBefore: tolerance, toleranceAfter: tolerance)
        currentTimeMs = ms
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

    func updateTrimBounds(startMs: Int64, endMs: Int64) {
        trimStartMs = startMs
        trimEndMs   = endMs
        removeBoundaryObserver()
        installBoundaryObserver(endMs: endMs)
    }

    // MARK: - Observers

    private func installBoundaryObserver(endMs: Int64) {
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
        let next = cur + 1 < store.clips.count ? cur + 1 : 0
        shouldAutoPlayNext = true
        store.selectedIndex = next
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
