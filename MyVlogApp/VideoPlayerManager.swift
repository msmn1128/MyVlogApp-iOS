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

    init() {
        player.volume = 1.0
        player.isMuted = false
        let interval = CMTime(value: 1, timescale: 30)
        periodicObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            guard time.isNumeric && time.seconds.isFinite else { return }
            let ms = Int64(time.seconds * 1000)
            self.currentTimeMs = ms
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
            let asset = try await AssetLoader.shared.load(clip: clip)
            guard !Task.isCancelled else { isLoading = false; return }
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
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

    // MARK: - Playback controls

    func play()               { player.play(); isPlaying = true }
    func pause()              { player.pause(); isPlaying = false }
    func togglePlayPause()    { isPlaying ? pause() : play() }
    func seekToStart()        { seek(to: trimStartMs) }

    func seek(to ms: Int64) {
        guard ms >= 0 else { return }
        let t = CMTime(value: ms, timescale: 1000)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTimeMs = ms
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
