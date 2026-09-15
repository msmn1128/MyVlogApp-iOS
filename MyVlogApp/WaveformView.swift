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
    // @StateにキャッシュしてonChangeで追従させる方式は更新の抜け漏れが起きやすかったため、
    // 「ドラッグ中でなければ毎回computedで出し直す」方式にしている。ドラッグ中だけ
    // ここに値を入れて据え置く（掴んだ瞬間の表示から指の下の的がズレないように）。
    @State private var lockedViewport: (start: Int64, end: Int64)? = nil
    // 描画専用のズーム範囲。指を離した瞬間のリフィットが一瞬でパッと切り替わり、
    // 直前まで見えていた位置と無関係な場所へ枠が飛んだように見えるのを防ぐため、
    // 実際のヒットテスト（xCoord/msAt）とは別に、描画だけこの値を滑らかに追従させる。
    // ドラッグ中はlockedViewportと常に同値なので実質アニメーションは発生せず、
    // ドラッグ終了時（isDragIdleがfalse→trueに切り替わる瞬間）だけ計算し直した
    // 新しいfitWaveformViewportへイーズさせる。
    @State private var displayViewport: (start: Int64, end: Int64)? = nil

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

    private var isLeftHandleActive: Bool {
        if case .trimLeft = drag { return true }
        return false
    }

    private var isRightHandleActive: Bool {
        if case .trimRight = drag { return true }
        return false
    }

    // つまみを掴んだ瞬間に太さが一段階で切り替わらないよう、太さそのものを補間する
    // （Android版WaveformTrimmerのstartHandleScale/endHandleScaleと同じ狙い）。
    // CanvasはSwiftUIのアニメーション機構と直接つながらないため、Animatableな
    // 透明ビュー（HandleScaleAnimator）を経由してアニメーション中の値を毎フレーム
    // 取り出し、Canvasが読むための@Stateへ橋渡ししている。
    @State private var leftHandleScale:  CGFloat = 1
    @State private var rightHandleScale: CGFloat = 1

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

                // Canvas描画のハンドル太さをアニメーションさせるための透明な橋渡し役
                HandleScaleAnimator(value: isLeftHandleActive ? 1.35 : 1) { leftHandleScale = $0 }
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isLeftHandleActive)
                HandleScaleAnimator(value: isRightHandleActive ? 1.35 : 1) { rightHandleScale = $0 }
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isRightHandleActive)

                // 表示ズームをdisplayViewportへ滑らかに追従させる透明な橋渡し役。
                // ドラッグ中はeffectiveViewportがlockedViewportのまま変化しないため
                // 実質何も起きず、ドラッグ終了（isDragIdle: false→true）の瞬間だけ
                // 新しいfitWaveformViewportへイーズする
                if let clip = store.selectedClip {
                    let vp = effectiveViewport(clip: clip)
                    ViewportAnimator(start: Double(vp.start), end: Double(vp.end)) { s, e in
                        displayViewport = (Int64(s), Int64(e))
                    }
                    .animation(.easeInOut(duration: 0.25), value: isDragIdle)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in onDragChange(v, size: sz) }
                    .onEnded   { v in onDragEnd(v, size: sz) }
            )
        }
        .task(id: store.selectedClip?.id) { await loadWaveform() }
        .onChange(of: store.selectedClip?.id) { _, _ in
            lockedViewport = nil
            displayViewport = nil
        }
    }

    // MARK: - Coordinate helpers
    // The time axis occupies [handleW, w-handleW] so handles never overflow.
    // ms は絶対時間、表示は effectiveViewport() のズーム範囲にマッピングする。

    /// ドラッグ中はlockedViewportを据え置き、そうでなければ選択範囲から毎回計算し直す
    /// （Android: LaunchedEffect(...isInteracting)相当だが、onChangeの発火漏れを避けるため
    /// キャッシュを信じず常に最新のclipから出し直す設計にしている）。
    private func effectiveViewport(clip: VlogClip) -> (start: Int64, end: Int64) {
        if let locked = lockedViewport, !isDragIdle { return locked }
        return Self.fitWaveformViewport(
            startMs: clip.startMs, endMs: clip.endMs, durationMs: clip.durationMs,
            fullThreshold: fitFullThreshold, marginRatio: fitMarginRatio,
            minMargin: fitMinMarginMs, minWindow: fitMinWindowMs
        )
    }

    private func xCoord(ms: Int64, w: CGFloat, clip: VlogClip) -> CGFloat {
        xCoord(ms: ms, w: w, viewport: effectiveViewport(clip: clip))
    }

    /// 描画専用：ヒットテストとは別に、displayViewportで滑らかに追従した位置を返す
    private func displayXCoord(ms: Int64, w: CGFloat, clip: VlogClip) -> CGFloat {
        xCoord(ms: ms, w: w, viewport: displayViewport ?? effectiveViewport(clip: clip))
    }

    private func xCoord(ms: Int64, w: CGFloat, viewport: (start: Int64, end: Int64)) -> CGFloat {
        guard w > 2 * handleW else { return handleW }
        let span = CGFloat(max(1, viewport.end - viewport.start))
        return handleW + (CGFloat(ms) - CGFloat(viewport.start)) / span * (w - 2 * handleW)
    }

    private func msAt(x: CGFloat, w: CGFloat, clip: VlogClip) -> Int64 {
        guard w > 2 * handleW else { return 0 }
        let vp = effectiveViewport(clip: clip)
        let span = CGFloat(max(1, vp.end - vp.start))
        let raw = CGFloat(vp.start) + (x - handleW) / (w - 2 * handleW) * span
        return Int64(max(0, min(CGFloat(clip.durationMs), raw)))
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
        let leftX  = displayXCoord(ms: clip.startMs, w: w, clip: clip)
        let rightX = displayXCoord(ms: clip.endMs, w: w, clip: clip)

        // ── Waveform bars ──
        // 各バーは「クリップ全体」を均等に分けた時間幅を受け持つ。以前はこの時間幅を
        // 無視してキャンバス全幅へ均等に敷き詰めていたため、つまみ（枠）だけが
        // ズーム後の位置へ移動する一方で波形の絵そのものは動かず、「枠が波形と無関係な
        // 場所へ飛んだ」ように見えていた。ここをAndroid版drawWaveformBars/TrackMetrics.msToXと
        // 同じ考え方に直し、各バーの中心時刻をdisplayXCoordでズーム後の位置へ変換して描く
        // （ズーム範囲外のバーは間引く）ことで、つまみだけでなく波形の絵自体がズームするようにする
        let bins   = waveform.isEmpty ? Array(repeating: Float(0.08), count: 240) : waveform
        let axisW  = w - 2 * handleW
        let midY   = h / 2
        let maxAmp = (h - railH * 2 - 2) / 2
        let vp     = displayViewport ?? effectiveViewport(clip: clip)
        let vpSpan = CGFloat(max(1, vp.end - vp.start))
        let pxPerMs   = axisW / vpSpan
        let bucketMs  = CGFloat(max(1, clip.durationMs)) / CGFloat(bins.count)
        let barW      = max(1, bucketMs * pxPerMs * 0.68)

        for (i, amp) in bins.enumerated() {
            let bucketCenterMs = Int64((CGFloat(i) + 0.5) * bucketMs)
            let barCenter = displayXCoord(ms: bucketCenterMs, w: w, clip: clip)
            guard barCenter >= handleW - barW && barCenter <= w - handleW + barW else { continue }
            let amplitude  = CGFloat(amp) * maxAmp
            let barRect    = CGRect(x: barCenter - barW / 2, y: midY - amplitude,
                                    width: barW, height: amplitude * 2)
            let inRange    = barCenter >= leftX && barCenter <= rightX
            ctx.fill(Path(roundedRect: barRect, cornerRadius: barW / 2),
                     with: .color(inRange ? AppColors.waveformFill : AppColors.waveformDim))
        }

        // ── Trim range rails (top and bottom)。区間ごと移動中は太くする（Android: isMovingTrim） ──
        let trimW = rightX - leftX
        let activeRailH = isMovingTrim ? railH + 2 : railH
        ctx.fill(Path(CGRect(x: leftX, y: 0,               width: trimW, height: activeRailH)), with: .color(AppColors.primary))
        ctx.fill(Path(CGRect(x: leftX, y: h - activeRailH, width: trimW, height: activeRailH)), with: .color(AppColors.primary))

        // ── Split lines ──
        // Android版drawSegmentSplitsはトリム範囲外の区切りも（ビューポート内である限り）
        // そのまま描く。トリムを動かせばまた見える位置なので隠す理由がない
        let splitColor = AppColors.splitLine(colorScheme)
        for splitMs in clip.splitPoints {
            let sx = displayXCoord(ms: splitMs, w: w, clip: clip)
            var path = Path()
            path.move(to: CGPoint(x: sx, y: railH + 1))
            path.addLine(to: CGPoint(x: sx, y: h - railH - 1))
            ctx.stroke(path, with: .color(splitColor), lineWidth: 2)
        }

        // ── Trim handles ──
        drawHandle(ctx: ctx, x: leftX,  h: h, isLeft: true,  scale: leftHandleScale)
        drawHandle(ctx: ctx, x: rightX, h: h, isLeft: false, scale: rightHandleScale)

        // ── Playhead ──
        // Android版と同じく、再生位置が今のビューポート外／トリム範囲外なら
        // 頭出し位置へクランプして描くのではなく、そもそも描かない
        let posMs = playerManager.currentTimeMs
        if posMs >= vp.start && posMs <= vp.end && posMs >= clip.startMs && posMs <= clip.endMs {
            let playX = displayXCoord(ms: posMs, w: w, clip: clip)
            var headPath = Path()
            headPath.move(to: CGPoint(x: playX, y: railH + 1))
            headPath.addLine(to: CGPoint(x: playX, y: h - railH - 1))
            ctx.stroke(headPath, with: .color(.white), lineWidth: 2)
            ctx.fill(Path(ellipseIn: CGRect(x: playX - 5, y: railH, width: 10, height: 10)),
                     with: .color(.white))
        }
    }

    private func drawHandle(ctx: GraphicsContext, x: CGFloat, h: CGFloat, isLeft: Bool, scale: CGFloat) {
        // 掴んでいる側は太さそのものをscaleぶん大きくする。トリム境界に接する辺
        // （左つまみなら右辺、右つまみなら左辺）は動かさず、外側へだけ広がるようにする
        let w     = handleW * scale
        let rx    = isLeft ? x - w : x
        let rect  = CGRect(x: rx, y: 0, width: w, height: h)
        ctx.fill(Path(roundedRect: rect, cornerRadius: 3 * scale), with: .color(AppColors.primary))
        let midX = rx + w / 2
        for dy: CGFloat in [-5, 0, 5] {
            var grip = Path()
            grip.move(to: CGPoint(x: midX - 2.5, y: h / 2 + dy))
            grip.addLine(to: CGPoint(x: midX + 2.5, y: h / 2 + dy))
            ctx.stroke(grip, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
        }
    }

    // MARK: - Segment number badges

    private func badgesOverlay(clip: VlogClip, size: CGSize) -> some View {
        let w     = size.width
        let splitColor = AppColors.splitLine(colorScheme)
        let lx    = displayXCoord(ms: clip.startMs, w: w, clip: clip)

        // Android版も「動画は切っていないので、ひとことの切れ目は自分で描かないと
        // 分からない」という理由でtexts.size > 1のときしかバッジ自体を出さない
        // （drawWaveformTrimmer内の `if (texts.size > 1) drawSegmentSplits(...)`）。
        // ここが抜けていたため、区切りが1つも無いクリップにまで「1」バッジが
        // 出てしまっていた。
        //
        // 以前はsplitPoints（2番目以降の区切り）しか見ておらず「1」バッジが出なかった
        // うえ、トリムで頭を落として表示されなくなった区間の番号まで出てしまっていた。
        // texts全体を見て、トリム開始位置より手前の区間は番号を出さず、いま表示中の
        // 区間の番号は実際の区切り位置ではなくトリム開始位置（lx）に追従させることで、
        // トリムを動かしても左端に張り付いたままにならないようにする
        let firstVisibleIndex = max(0, clip.texts.lastIndex { $0.startMs <= clip.startMs } ?? 0)

        return ZStack(alignment: .topLeading) {
            if clip.texts.count > 1 {
                ForEach(Array(clip.texts.enumerated()), id: \.offset) { index, segment in
                    if index >= firstVisibleIndex {
                        let sx = displayXCoord(ms: segment.startMs, w: w, clip: clip)
                        let anchorX = index == firstVisibleIndex ? lx : sx + 3
                        // バッジ自体には触らせない（表示専用）。以前はここに独自の
                        // onTapGestureを付けていたが、親ZStackのDragGesture(minimumDistance: 0)と
                        // 同じ領域に別のジェスチャー認識器が重なることでSwiftUI側の判定が乱れ、
                        // 分割マーカーがある間はトリム範囲のタップがまるごと効かなくなる
                        // 不具合の原因になっていた。区切り付近のタップは親のDragGestureの
                        // ヒットテスト（onDragChangeのnearestSplitDist判定）で既に拾えるため、
                        // バッジ側に別ジェスチャーを持たせる必要はない。
                        //
                        // .offset(x:)は使わない。このZStackはalignment: .topLeadingだが、
                        // 小さい固有サイズのビューに.offset()を使うと、期待通り左上を
                        // 基準に動いてくれず中央寄りの位置にずれる現象を確認した。
                        // .position()は親の座標系の絶対位置を直接指定するため、
                        // コンテナのalignmentに影響されず確実に狙った位置に置ける
                        // （分割マーカーの再生ヘッド等、元々あったコードも.position()を
                        // 使っていた）。
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(splitColor)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .position(x: min(max(anchorX, 0), w - 10) + 10, y: 10)
                            .allowsHitTesting(false)
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
        let leftX  = xCoord(ms: clip.startMs, w: w, clip: clip)
        let rightX = xCoord(ms: clip.endMs, w: w, clip: clip)

        // Determine mode on first event (translation ≈ zero)。
        // Android hitTestTrim: 端 > 分割ライン > 本体、の優先順で一番近いものを掴む。
        if case .none = drag {
            // ドラッグ開始の瞬間の表示範囲で固定する（Android: isInteracting中は据え置き）
            lockedViewport = effectiveViewport(clip: clip)
            playerManager.beginInteractiveSeek()
            let sl = value.startLocation.x
            let dLeft  = abs(sl - leftX)
            let dRight = abs(sl - rightX)
            let nearestHandleDist = min(dLeft, dRight)

            var nearestSplitIndex: Int? = nil
            var nearestSplitDist: CGFloat = .greatestFiniteMagnitude
            for (i, seg) in clip.texts.enumerated() where i > 0 {
                let sx = xCoord(ms: seg.startMs, w: w, clip: clip)
                let d  = abs(sl - sx)
                if d < nearestSplitDist { nearestSplitDist = d; nearestSplitIndex = i }
            }

            if nearestHandleDist <= handleHit && nearestHandleDist <= nearestSplitDist {
                drag = dLeft <= dRight ? .trimLeft(grabOffset: sl - leftX) : .trimRight(grabOffset: sl - rightX)
            } else if let splitIdx = nearestSplitIndex, nearestSplitDist <= handleHit {
                let splitX = xCoord(ms: clip.texts[splitIdx].startMs, w: w, clip: clip)
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
            let newMs = max(0, min(clip.endMs - VlogClip.minTrimMs, msAt(x: newX, w: w, clip: clip)))
            store.updateTrim(startMs: newMs, endMs: clip.endMs)
            playerManager.seek(to: newMs)
            playerManager.updateTrimBounds(startMs: newMs, endMs: clip.endMs)

        case .trimRight(let off):
            let newX  = max(leftX + handleW, min(w - handleW, loc - off))
            let newMs = max(clip.startMs + VlogClip.minTrimMs,
                            min(clip.durationMs, msAt(x: newX, w: w, clip: clip)))
            store.updateTrim(startMs: clip.startMs, endMs: newMs)
            playerManager.seek(to: newMs)
            playerManager.updateTrimBounds(startMs: clip.startMs, endMs: newMs)

        case .splitMove(let index, let off):
            let newMs = msAt(x: loc - off, w: w, clip: clip)
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
                let seekMs = max(clip.startMs, min(clip.endMs, msAt(x: loc, w: w, clip: clip)))
                playerManager.seek(to: seekMs)
            }

        case .seeking:
            let seekMs = max(clip.startMs, min(clip.endMs, msAt(x: loc, w: w, clip: clip)))
            playerManager.seek(to: seekMs)

        case .movingTrim(let originalStart, let anchorX, _):
            let vp = effectiveViewport(clip: clip)
            let span = CGFloat(max(1, vp.end - vp.start))
            let pxPerMs = (w - 2 * handleW) / span
            guard pxPerMs > 0 else { return }
            let deltaMs = Int64((loc - anchorX) / pxPerMs)
            if let result = store.moveTrim(targetStartMs: originalStart + deltaMs) {
                playerManager.updateTrimBounds(startMs: result.startMs, endMs: result.endMs)
                playerManager.seek(to: max(result.startMs, min(result.endMs, msAt(x: loc, w: w, clip: clip))))
            }

        case .none:
            break
        }
    }

    private func onDragEnd(_ value: DragGesture.Value, size: CGSize) {
        pendingBodyTask?.cancel(); pendingBodyTask = nil
        defer { playerManager.endInteractiveSeek() }

        switch drag {
        case .seeking(let wasPlaying):
            if wasPlaying { playerManager.play() }

        case .pendingBody(let downX):
            // 動かさずに離した＝タップ。その場へ頭出し（Android: DragOutcome.Released）
            if let clip = store.selectedClip {
                let seekMs = max(clip.startMs, min(clip.endMs, msAt(x: downX, w: size.width, clip: clip)))
                playerManager.seek(to: seekMs)
            }

        case .splitMove:
            // 分割マーカーの近くをドラッグせずタップしただけだと、grabOffset
            // （掴んだ位置と分割マーカーの位置の差）がそのまま効いて、シーク先が
            // 常に分割マーカーのすぐ近くへ引き戻されてしまう
            // （「分割するとシークバーが分割の場所で固定される」不具合）。
            // 実際に動かした形跡（moveSlopを超える移動）が無ければタップとして扱い、
            // grabOffsetを無視して実際にタップした位置へそのままシークし直す。
            if abs(value.location.x - value.startLocation.x) <= moveSlop, let clip = store.selectedClip {
                let seekMs = max(clip.startMs, min(clip.endMs, msAt(x: value.location.x, w: size.width, clip: clip)))
                playerManager.seek(to: seekMs)
            }

        case .movingTrim(_, let anchorX, let wasPlaying):
            if wasPlaying { playerManager.play() }
            // schedulePendingBodyTimeout()が長押しタイムアウトで.movingTrimへ切り替えた後、
            // 指を動かさないまま離すと「区間移動」としては何も起きず（onDragChangeが
            // 一度も呼ばれないため）、実質タップだったのにシークが一切行われなかった
            // （「分割位置はドラッグで動くのに、ただのタップだと再生バーが動かない」不具合）。
            // 離した位置がanchorXからほぼ動いていなければ、タップとして扱いその場へ頭出しする。
            if abs(value.location.x - anchorX) <= moveSlop, let clip = store.selectedClip {
                let seekMs = max(clip.startMs, min(clip.endMs, msAt(x: value.location.x, w: size.width, clip: clip)))
                playerManager.seek(to: seekMs)
            }

        default:
            break
        }
        drag = .none
        // ロック解除。次の再描画からは選択範囲に合わせて毎回計算し直される
        lockedViewport = nil
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

/// SwiftUIのアニメーション機構（withAnimation/.animation(value:)）は通常View修飾子の
/// パラメータを対象にするため、Canvas描画クロージャの中で直接使っている生の値は
/// そのままでは補間されない。この透明ビューはanimatableDataとしてvalueを持たせることで
/// SwiftUIのアニメーションエンジンに毎フレームの中間値を計算させ、onChangeで
/// 呼び出し元へ橋渡しする（Canvasアニメーションの定番手法）。
private struct HandleScaleAnimator: View, Animatable {
    var value: CGFloat
    let onChange: (CGFloat) -> Void

    var animatableData: CGFloat {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Color.clear
            .onAppear { onChange(value) }
            .onChange(of: value) { _, newValue in onChange(newValue) }
    }
}

/// HandleScaleAnimatorと同じ橋渡し手法で、波形の表示ズーム範囲(start/end)を
/// AnimatablePairとして滑らかに追従させる
private struct ViewportAnimator: View, Animatable {
    var start: Double
    var end:   Double
    let onChange: (Double, Double) -> Void

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    var body: some View {
        Color.clear
            .onAppear { onChange(start, end) }
            .onChange(of: start) { _, _ in onChange(start, end) }
            .onChange(of: end)   { _, _ in onChange(start, end) }
    }
}
