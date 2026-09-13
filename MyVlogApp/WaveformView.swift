import SwiftUI
import AVFoundation

struct WaveformView: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager
    @Environment(\.colorScheme) var colorScheme

    @State private var waveform:  [Float] = []
    @State private var isLoading: Bool    = false
    @State private var drag:      ActiveDrag = .none
    @State private var pendingBodyTask: Task<Void, Never>? = nil
    // 波形の表示範囲（ズーム）。長い動画で短くトリムすると、つまみが端に寄って
    // 操作しづらくなるのを防ぐため選択範囲＋余白へズームする（Android: fitWaveformViewport）。
    // ドラッグ中は据え置き、操作の区切り（掴み直し・プリセット適用など）でだけ追従させる。
    @State private var viewStartMs: Int64 = 0
    @State private var viewEndMs:   Int64 = 0

    private enum ActiveDrag {
        case none
        case trimLeft(grabOffset: CGFloat)
        case trimRight(grabOffset: CGFloat)
        case splitMove(index: Int, grabOffset: CGFloat)
        /// 本体を触った直後：動くか、長押しタイムアウトが来るまで様子見（Android: dragBodyOrMove）
        case pendingBody(downX: CGFloat)
        case seeking(wasPlaying: Bool)
        case movingTrim(originalStart: Int64, anchorX: CGFloat, wasPlaying: Bool)
    }

    private var isMovingTrim: Bool {
        if case .movingTrim = drag { return true }
        return false
    }

    private var isDragIdle: Bool {
        if case .none = drag { return true }
        return false
    }

    private let handleW:    CGFloat = 12
    private let handleHit:  CGFloat = 28
    private let railH:      CGFloat = 3
    private let moveSlop:   CGFloat = 8
    private let longPressSeconds: Double = 0.5

    // Android: WAVEFORM_FIT_FULL_THRESHOLD / MARGIN_RATIO / MIN_MARGIN_MS / MIN_WINDOW_MS
    private let fitFullThreshold: Double = 0.6
    private let fitMarginRatio:   Double = 0.5
    private let fitMinMarginMs:   Int64  = 300
    private let fitMinWindowMs:   Int64  = 3_000

    var body: some View {
        GeometryReader { geo in
            let sz = geo.size
            ZStack {
                // Main canvas
                Canvas { ctx, size in
                    drawWaveform(ctx: ctx, size: size)
                }
                .drawingGroup()

                // Split-line number badges (SwiftUI overlay for crisp text)
                if let clip = store.selectedClip {
                    badgesOverlay(clip: clip, size: sz)
                }

                if isLoading {
                    ProgressView().tint(AppColors.primary)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in onDragChange(v, size: sz) }
                    .onEnded   { v in onDragEnd(v, size: sz) }
            )
        }
        .onAppear { refreshViewportIfIdle(force: true) }
        .onChange(of: store.selectedClip?.id) { _, _ in refreshViewportIfIdle(force: true) }
        .task(id: store.selectedClip?.id) { await loadWaveform() }
        .onChange(of: store.selectedClip?.startMs) { _, _ in refreshViewportIfIdle() }
        .onChange(of: store.selectedClip?.endMs)   { _, _ in refreshViewportIfIdle() }
    }

    // MARK: - Coordinate helpers
    // The time axis occupies [handleW, w-handleW] so handles never overflow.
    // ms は絶対時間、表示は viewStartMs...viewEndMs のズーム範囲にマッピングする。

    /// viewStartMs/viewEndMsが未初期化（0...0）でも壊れた極小レンジにならないよう、
    /// その場合はクリップ全長へフォールバックする。
    private func effectiveViewport(durationMs: Int64) -> (start: Int64, end: Int64) {
        if viewEndMs > viewStartMs { return (viewStartMs, viewEndMs) }
        return (0, max(1, durationMs))
    }

    private func xCoord(ms: Int64, w: CGFloat, durationMs: Int64) -> CGFloat {
        guard w > 2 * handleW else { return handleW }
        let vp = effectiveViewport(durationMs: durationMs)
        let span = CGFloat(max(1, vp.end - vp.start))
        return handleW + (CGFloat(ms) - CGFloat(vp.start)) / span * (w - 2 * handleW)
    }

    private func msAt(x: CGFloat, w: CGFloat, durationMs: Int64) -> Int64 {
        guard w > 2 * handleW else { return 0 }
        let vp = effectiveViewport(durationMs: durationMs)
        let span = CGFloat(max(1, vp.end - vp.start))
        let raw = CGFloat(vp.start) + (x - handleW) / (w - 2 * handleW) * span
        return Int64(max(0, min(CGFloat(durationMs), raw)))
    }

    /// ドラッグ中でなければ、選択範囲に合わせて表示範囲を追従させる（Android: LaunchedEffect(...isInteracting)）
    private func refreshViewportIfIdle(force: Bool = false) {
        guard force || isDragIdle, let clip = store.selectedClip else { return }
        let range = Self.fitWaveformViewport(
            startMs: clip.startMs, endMs: clip.endMs, durationMs: clip.durationMs,
            fullThreshold: fitFullThreshold, marginRatio: fitMarginRatio,
            minMargin: fitMinMarginMs, minWindow: fitMinWindowMs
        )
        viewStartMs = range.start
        viewEndMs   = range.end
    }

    /// 選択範囲(startMs〜endMs)に合わせて波形の表示範囲を決める（Android: fitWaveformViewport）。
    /// 選択範囲が全体の大部分を占めるときは全体表示のまま、一部だけのときは選択範囲＋余白へズームする。
    private static func fitWaveformViewport(
        startMs: Int64, endMs: Int64, durationMs: Int64,
        fullThreshold: Double, marginRatio: Double, minMargin: Int64, minWindow: Int64
    ) -> (start: Int64, end: Int64) {
        guard durationMs > 0 else { return (0, 0) }
        let selectionSpan = max(0, endMs - startMs)
        if Double(selectionSpan) >= Double(durationMs) * fullThreshold { return (0, durationMs) }

        let margin = max(Int64(Double(selectionSpan) * marginRatio), minMargin)
        var viewStart = startMs - margin
        var viewEnd   = endMs + margin

        let shortfall = minWindow - (viewEnd - viewStart)
        if shortfall > 0 {
            viewStart -= shortfall / 2
            viewEnd   += shortfall - shortfall / 2
        }

        // 動画の端に近い選択範囲では、片側に伸ばせないぶんを反対側へ回して表示幅を保つ
        if viewStart < 0 {
            viewEnd -= viewStart
            viewStart = 0
        }
        if viewEnd > durationMs {
            viewStart -= (viewEnd - durationMs)
            viewEnd = durationMs
        }
        return (max(0, viewStart), min(durationMs, viewEnd))
    }

    // MARK: - Canvas drawing

    private func drawWaveform(ctx: GraphicsContext, size: CGSize) {
        guard let clip = store.selectedClip else { return }
        let w   = size.width
        let h   = size.height
        let leftX  = xCoord(ms: clip.startMs, w: w, durationMs: clip.durationMs)
        let rightX = xCoord(ms: clip.endMs, w: w, durationMs: clip.durationMs)

        // ── Waveform bars (fill the time-axis region only) ──
        let bins     = waveform.isEmpty ? Array(repeating: Float(0.08), count: 240) : waveform
        let axisW    = w - 2 * handleW
        let barW     = axisW / CGFloat(bins.count)
        let midY     = h / 2
        let maxAmp   = (h - railH * 2 - 2) / 2

        for (i, amp) in bins.enumerated() {
            let x          = handleW + CGFloat(i) * barW
            let barCenter  = x + barW / 2
            let amplitude  = CGFloat(amp) * maxAmp
            let barRect    = CGRect(x: x + 0.5, y: midY - amplitude,
                                    width: max(1, barW - 1), height: amplitude * 2)
            let inRange    = barCenter >= leftX && barCenter <= rightX
            ctx.fill(Path(barRect),
                     with: .color(inRange ? AppColors.waveformFill : AppColors.waveformDim))
        }

        // ── Trim range rails (top and bottom)。区間ごと移動中は太くする（Android: isMovingTrim） ──
        let trimW = rightX - leftX
        let activeRailH = isMovingTrim ? railH + 2 : railH
        ctx.fill(Path(CGRect(x: leftX, y: 0,               width: trimW, height: activeRailH)), with: .color(AppColors.primary))
        ctx.fill(Path(CGRect(x: leftX, y: h - activeRailH, width: trimW, height: activeRailH)), with: .color(AppColors.primary))

        // ── Split lines ──
        let splitColor = AppColors.splitLine(colorScheme)
        for splitMs in clip.splitPoints {
            let sx = xCoord(ms: splitMs, w: w, durationMs: clip.durationMs)
            guard sx > leftX && sx < rightX else { continue }
            var path = Path()
            path.move(to: CGPoint(x: sx, y: railH + 1))
            path.addLine(to: CGPoint(x: sx, y: h - railH - 1))
            ctx.stroke(path, with: .color(splitColor), lineWidth: 2)
        }

        // ── Trim handles ──
        drawHandle(ctx: ctx, x: leftX,  h: h, isLeft: true)
        drawHandle(ctx: ctx, x: rightX, h: h, isLeft: false)

        // ── Playhead ──
        let posMs   = playerManager.currentTimeMs
        let clamped = max(clip.startMs, min(clip.endMs, posMs))
        let playX   = xCoord(ms: clamped, w: w, durationMs: clip.durationMs)
        var headPath = Path()
        headPath.move(to: CGPoint(x: playX, y: railH + 1))
        headPath.addLine(to: CGPoint(x: playX, y: h - railH - 1))
        ctx.stroke(headPath, with: .color(.white), lineWidth: 2)
        ctx.fill(Path(ellipseIn: CGRect(x: playX - 5, y: railH, width: 10, height: 10)),
                 with: .color(.white))
    }

    private func drawHandle(ctx: GraphicsContext, x: CGFloat, h: CGFloat, isLeft: Bool) {
        let rx    = isLeft ? x - handleW : x
        let rect  = CGRect(x: rx, y: 0, width: handleW, height: h)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(AppColors.primary))
        let midX = rx + handleW / 2
        for dy: CGFloat in [-5, 0, 5] {
            var grip = Path()
            grip.move(to: CGPoint(x: midX - 2.5, y: h / 2 + dy))
            grip.addLine(to: CGPoint(x: midX + 2.5, y: h / 2 + dy))
            ctx.stroke(grip, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
        }
    }

    // MARK: - Segment number badges

    private func badgesOverlay(clip: VlogClip, size: CGSize) -> some View {
        let dur   = CGFloat(max(1, clip.durationMs))
        let w     = size.width
        let splitColor = AppColors.splitLine(colorScheme)

        return ZStack(alignment: .topLeading) {
            ForEach(Array(clip.splitPoints.enumerated()), id: \.offset) { idx, splitMs in
                let sx  = xCoord(ms: splitMs, w: w, durationMs: clip.durationMs)
                let lx  = xCoord(ms: clip.startMs, w: w, durationMs: clip.durationMs)
                let rx  = xCoord(ms: clip.endMs, w: w, durationMs: clip.durationMs)
                if sx > lx && sx < rx {
                    // バッジをタップすると区切りへ正確にシークする（許容誤差の外から「解除」を
                    // 押せるようにするための導線。以前は表示専用でタップできなかった）
                    Text("\(idx + 2)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(splitColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .position(x: sx, y: size.height * 0.14)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            playerManager.seek(to: splitMs)
                        }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Gesture handling

    private func onDragChange(_ value: DragGesture.Value, size: CGSize) {
        guard let clip = store.selectedClip else { return }
        let w   = size.width
        let leftX  = xCoord(ms: clip.startMs, w: w, durationMs: clip.durationMs)
        let rightX = xCoord(ms: clip.endMs, w: w, durationMs: clip.durationMs)

        // Determine mode on first event (translation ≈ zero)。
        // Android hitTestTrim: 端 > 分割ライン > 本体、の優先順で一番近いものを掴む。
        if case .none = drag {
            let sl = value.startLocation.x
            let dLeft  = abs(sl - leftX)
            let dRight = abs(sl - rightX)
            let nearestHandleDist = min(dLeft, dRight)

            var nearestSplitIndex: Int? = nil
            var nearestSplitDist: CGFloat = .greatestFiniteMagnitude
            for (i, seg) in clip.texts.enumerated() where i > 0 {
                let sx = xCoord(ms: seg.startMs, w: w, durationMs: clip.durationMs)
                let d  = abs(sl - sx)
                if d < nearestSplitDist { nearestSplitDist = d; nearestSplitIndex = i }
            }

            if nearestHandleDist <= handleHit && nearestHandleDist <= nearestSplitDist {
                drag = dLeft <= dRight ? .trimLeft(grabOffset: sl - leftX) : .trimRight(grabOffset: sl - rightX)
            } else if let splitIdx = nearestSplitIndex, nearestSplitDist <= handleHit {
                let splitX = xCoord(ms: clip.texts[splitIdx].startMs, w: w, durationMs: clip.durationMs)
                drag = .splitMove(index: splitIdx, grabOffset: sl - splitX)
            } else {
                drag = .pendingBody(downX: sl)
                schedulePendingBodyTimeout(downX: sl)
            }
        }

        let loc = value.location.x

        switch drag {
        case .trimLeft(let off):
            let newX  = max(handleW, min(rightX - handleW, loc - off))
            let newMs = max(0, min(clip.endMs - VlogClip.minTrimMs, msAt(x: newX, w: w, durationMs: clip.durationMs)))
            store.updateTrim(startMs: newMs, endMs: clip.endMs)
            playerManager.seek(to: newMs)
            playerManager.updateTrimBounds(startMs: newMs, endMs: clip.endMs)

        case .trimRight(let off):
            let newX  = max(leftX + handleW, min(w - handleW, loc - off))
            let newMs = max(clip.startMs + VlogClip.minTrimMs,
                            min(clip.durationMs, msAt(x: newX, w: w, durationMs: clip.durationMs)))
            store.updateTrim(startMs: clip.startMs, endMs: newMs)
            playerManager.seek(to: newMs)
            playerManager.updateTrimBounds(startMs: clip.startMs, endMs: newMs)

        case .splitMove(let index, let off):
            let newMs = msAt(x: loc - off, w: w, durationMs: clip.durationMs)
            if let clamped = store.moveSplit(index: index, newAtMs: newMs) {
                playerManager.seek(to: clamped)
            }

        case .pendingBody(let downX):
            let movedX = abs(value.location.x - downX)
            let movedY = abs(value.translation.height)
            if movedX > moveSlop || movedY > moveSlop {
                pendingBodyTask?.cancel(); pendingBodyTask = nil
                let wasPlaying = playerManager.isPlaying
                if wasPlaying { playerManager.pause() }
                drag = .seeking(wasPlaying: wasPlaying)
                let seekMs = max(clip.startMs, min(clip.endMs, msAt(x: loc, w: w, durationMs: clip.durationMs)))
                playerManager.seek(to: seekMs)
            }

        case .seeking:
            let seekMs = max(clip.startMs, min(clip.endMs, msAt(x: loc, w: w, durationMs: clip.durationMs)))
            playerManager.seek(to: seekMs)

        case .movingTrim(let originalStart, let anchorX, _):
            let vp = effectiveViewport(durationMs: clip.durationMs)
            let span = CGFloat(max(1, vp.end - vp.start))
            let pxPerMs = (w - 2 * handleW) / span
            guard pxPerMs > 0 else { return }
            let deltaMs = Int64((loc - anchorX) / pxPerMs)
            if let result = store.moveTrim(targetStartMs: originalStart + deltaMs) {
                playerManager.updateTrimBounds(startMs: result.startMs, endMs: result.endMs)
                playerManager.seek(to: max(result.startMs, min(result.endMs, msAt(x: loc, w: w, durationMs: clip.durationMs))))
            }

        case .none:
            break
        }
    }

    private func onDragEnd(_ value: DragGesture.Value, size: CGSize) {
        pendingBodyTask?.cancel(); pendingBodyTask = nil

        switch drag {
        case .seeking(let wasPlaying):
            if wasPlaying { playerManager.play() }

        case .pendingBody(let downX):
            // 動かさずに離した＝タップ。その場へ頭出し（Android: DragOutcome.Released）
            if let clip = store.selectedClip {
                let seekMs = max(clip.startMs, min(clip.endMs, msAt(x: downX, w: size.width, durationMs: clip.durationMs)))
                playerManager.seek(to: seekMs)
            }

        case .movingTrim(_, _, let wasPlaying):
            if wasPlaying { playerManager.play() }

        default:
            break
        }
        drag = .none
        refreshViewportIfIdle()
    }

    /// 動かさず[longPressSeconds]経過したら「区間ごと移動」へ切り替える（Android: dragBodyOrMove）
    private func schedulePendingBodyTimeout(downX: CGFloat) {
        pendingBodyTask?.cancel()
        pendingBodyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(longPressSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard case .pendingBody = drag, let clip = store.selectedClip else { return }
            let wasPlaying = playerManager.isPlaying
            if wasPlaying { playerManager.pause() }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            drag = .movingTrim(originalStart: clip.startMs, anchorX: downX, wasPlaying: wasPlaying)
        }
    }

    // MARK: - Waveform loading

    private func loadWaveform() async {
        guard let clip = store.selectedClip else { waveform = []; return }
        await MainActor.run { isLoading = true; waveform = [] }
        do {
            let asset = try await AssetLoader.shared.load(clip: clip)
            let data  = await WaveformExtractor.shared.extract(asset: asset, clipID: clip.id)
            await MainActor.run { waveform = data; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}
