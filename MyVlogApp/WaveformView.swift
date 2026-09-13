import SwiftUI
import AVFoundation

struct WaveformView: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager
    @Environment(\.colorScheme) var colorScheme

    @State private var waveform:  [Float] = []
    @State private var isLoading: Bool    = false
    @State private var drag:      ActiveDrag = .none

    private enum ActiveDrag {
        case none
        case trimLeft(grabOffset: CGFloat)
        case trimRight(grabOffset: CGFloat)
        case seeking(wasPlaying: Bool)
    }

    private let handleW:    CGFloat = 12
    private let handleHit:  CGFloat = 28
    private let railH:      CGFloat = 3

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
                    .onEnded   { v in onDragEnd(v) }
            )
        }
        .task(id: store.selectedClip?.id) { await loadWaveform() }
    }

    // MARK: - Coordinate helpers
    // The time axis occupies [handleW, w-handleW] so handles never overflow.

    private func xCoord(ms: Int64, dur: CGFloat, w: CGFloat) -> CGFloat {
        guard dur > 0, w > 2 * handleW else { return handleW }
        return handleW + CGFloat(ms) / dur * (w - 2 * handleW)
    }

    private func msAt(x: CGFloat, dur: CGFloat, w: CGFloat) -> Int64 {
        guard w > 2 * handleW else { return 0 }
        return Int64(max(0, min(dur, (x - handleW) / (w - 2 * handleW) * dur)))
    }

    // MARK: - Canvas drawing

    private func drawWaveform(ctx: GraphicsContext, size: CGSize) {
        guard let clip = store.selectedClip else { return }
        let w   = size.width
        let h   = size.height
        let dur = CGFloat(max(1, clip.durationMs))
        let leftX  = xCoord(ms: clip.startMs, dur: dur, w: w)
        let rightX = xCoord(ms: clip.endMs,   dur: dur, w: w)

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

        // ── Trim range rails (top and bottom) ──
        let trimW = rightX - leftX
        ctx.fill(Path(CGRect(x: leftX, y: 0,          width: trimW, height: railH)), with: .color(AppColors.primary))
        ctx.fill(Path(CGRect(x: leftX, y: h - railH,  width: trimW, height: railH)), with: .color(AppColors.primary))

        // ── Split lines ──
        let splitColor = AppColors.splitLine(colorScheme)
        for splitMs in clip.splitPoints {
            let sx = xCoord(ms: splitMs, dur: dur, w: w)
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
        let playX   = xCoord(ms: clamped, dur: dur, w: w)
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
                let sx  = xCoord(ms: splitMs,      dur: dur, w: w)
                let lx  = xCoord(ms: clip.startMs, dur: dur, w: w)
                let rx  = xCoord(ms: clip.endMs,   dur: dur, w: w)
                if sx > lx && sx < rx {
                    Text("\(idx + 2)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(splitColor)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .position(x: sx, y: size.height * 0.14)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    // MARK: - Gesture handling

    private func onDragChange(_ value: DragGesture.Value, size: CGSize) {
        guard let clip = store.selectedClip else { return }
        let w   = size.width
        let dur = CGFloat(clip.durationMs)
        let leftX  = xCoord(ms: clip.startMs, dur: dur, w: w)
        let rightX = xCoord(ms: clip.endMs,   dur: dur, w: w)

        // Determine mode on first event (translation ≈ zero)
        if case .none = drag {
            let sl = value.startLocation.x
            let dLeft  = abs(sl - leftX)
            let dRight = abs(sl - rightX)
            if dLeft < handleHit && (dLeft <= dRight) {
                drag = .trimLeft(grabOffset: sl - leftX)
            } else if dRight < handleHit {
                drag = .trimRight(grabOffset: sl - rightX)
            } else {
                drag = .seeking(wasPlaying: playerManager.isPlaying)
                if playerManager.isPlaying { playerManager.pause() }
            }
        }

        let loc = value.location.x

        switch drag {
        case .trimLeft(let off):
            let newX  = max(handleW, min(rightX - handleW, loc - off))
            let newMs = max(0, min(clip.endMs - VlogClip.minTrimMs, msAt(x: newX, dur: dur, w: w)))
            store.updateTrim(startMs: newMs, endMs: clip.endMs)
            playerManager.seek(to: newMs)
            playerManager.updateTrimBounds(startMs: newMs, endMs: clip.endMs)

        case .trimRight(let off):
            let newX  = max(leftX + handleW, min(w - handleW, loc - off))
            let newMs = max(clip.startMs + VlogClip.minTrimMs,
                            min(clip.durationMs, msAt(x: newX, dur: dur, w: w)))
            store.updateTrim(startMs: clip.startMs, endMs: newMs)
            playerManager.seek(to: newMs)
            playerManager.updateTrimBounds(startMs: clip.startMs, endMs: newMs)

        case .seeking:
            let seekMs = max(clip.startMs, min(clip.endMs, msAt(x: loc, dur: dur, w: w)))
            playerManager.seek(to: seekMs)

        case .none:
            break
        }
    }

    private func onDragEnd(_ value: DragGesture.Value) {
        if case .seeking(let wasPlaying) = drag, wasPlaying {
            playerManager.play()
        }
        drag = .none
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
