import SwiftUI

// =====================================================================================
// WaveformView.swiftからの切り出し。波形トリマーのジェスチャー判定・ドラッグ処理だけを
// まとめたもの（描画がWaveformDrawing.swiftへ切り出されているのと同じ考え方。
// Android: WaveformTrimmerGestures.ktと同じ分離）。
// 状態（drag/lockedViewport等）と座標ヘルパー（effectiveViewport/geometry/xCoord/msAt）は
// WaveformView.swift側の宣言をそのまま使うため、このファイルからも参照できるよう
// 該当プロパティ・関数はprivateを外してある。
// =====================================================================================

extension WaveformView {
    // MARK: - Gesture handling

    func onDragChange(_ value: DragGesture.Value, size: CGSize) {
        guard let clip = store.selectedClip else { return }
        let w   = size.width
        let leftX  = xCoord(ms: clip.startMs, w: w, clip: clip)
        let rightX = xCoord(ms: clip.endMs, w: w, clip: clip)

        // Determine mode on first event (translation ≈ zero)。
        if case .none = drag {
            // ドラッグ開始の瞬間の表示範囲で固定する（Android: isInteracting中は据え置き）
            lockedViewport = effectiveViewport(clip: clip)
            playerManager.beginInteractiveSeek()
            drag = beginDrag(at: value.startLocation.x, w: w, clip: clip, leftX: leftX, rightX: rightX)
            if case .pendingBody(let downX) = drag {
                schedulePendingBodyTimeout(downX: downX, w: w)
            }
        }

        let loc = value.location.x

        switch drag {
        case .trimLeft(let off):
            dragTrimHandle(isLeft: true, grabOffset: off, loc: loc, w: w, clip: clip)

        case .trimRight(let off):
            dragTrimHandle(isLeft: false, grabOffset: off, loc: loc, w: w, clip: clip)

        case .splitMove(let index, let off):
            dragSplitLine(index: index, grabOffset: off, loc: loc, w: w, clip: clip)

        case .pendingBody(let downX):
            dragPendingBody(downX: downX, value: value, w: w, clip: clip)

        case .seeking:
            dragSeek(loc: loc, w: w, clip: clip)

        case .movingTrim(_, let grabOffset, _):
            dragMoveTrim(grabOffset: grabOffset, loc: loc, w: w, clip: clip)

        case .none:
            break
        }
    }

    func onDragEnd(_ value: DragGesture.Value, size: CGSize) {
        pendingBodyTask?.cancel(); pendingBodyTask = nil
        defer { playerManager.endInteractiveSeek() }

        switch drag {
        case .seeking(let wasPlaying):
            if wasPlaying { playerManager.play() }

        case .pendingBody(let downX):
            // 動かさずに離した＝タップ。その場へ頭出し（Android: DragOutcome.Released）
            if let clip = store.selectedClip {
                finishTap(at: downX, w: size.width, clip: clip)
            }

        case .splitMove:
            // 分割マーカーの近くをドラッグせずタップしただけだと、grabOffset
            // （掴んだ位置と分割マーカーの位置の差）がそのまま効いて、シーク先が
            // 常に分割マーカーのすぐ近くへ引き戻されてしまう
            // （「分割するとシークバーが分割の場所で固定される」不具合）。
            // 実際に動かした形跡（moveSlopを超える移動）が無ければタップとして扱い、
            // grabOffsetを無視して実際にタップした位置へそのままシークし直す。
            if abs(value.location.x - value.startLocation.x) <= moveSlop, let clip = store.selectedClip {
                finishTap(at: value.location.x, w: size.width, clip: clip)
            }

        case .movingTrim(let anchorX, _, let wasPlaying):
            if wasPlaying { playerManager.play() }
            // schedulePendingBodyTimeout()が長押しタイムアウトで.movingTrimへ切り替えた後、
            // 指を動かさないまま離すと「区間移動」としては何も起きず（onDragChangeが
            // 一度も呼ばれないため）、実質タップだったのにシークが一切行われなかった
            // （「分割位置はドラッグで動くのに、ただのタップだと再生バーが動かない」不具合）。
            // 離した位置がanchorXからほぼ動いていなければ、タップとして扱いその場へ頭出しする。
            if abs(value.location.x - anchorX) <= moveSlop, let clip = store.selectedClip {
                finishTap(at: value.location.x, w: size.width, clip: clip)
            }

        default:
            break
        }
        drag = .none
        stopEdgeScrollTask()
        // ロック解除。次の再描画からは選択範囲に合わせて毎回計算し直される
        lockedViewport = nil
    }

    // MARK: - Gesture handlers (Android: dragTrimHandle/dragSplitLine/dragBodyOrMoveに相当)

    /// 指を置いた位置が、つまみ・分割ライン・本体のどれに最も近いかを判定する
    /// （Android: hitTestTrim）。端 > 分割ライン > 本体、の優先順で一番近いものを掴む。
    private func beginDrag(at startX: CGFloat, w: CGFloat, clip: VlogClip, leftX: CGFloat, rightX: CGFloat) -> ActiveDrag {
        let dLeft  = abs(startX - leftX)
        let dRight = abs(startX - rightX)
        let nearestHandleDist = min(dLeft, dRight)

        var nearestSplitIndex: Int? = nil
        var nearestSplitDist: CGFloat = .greatestFiniteMagnitude
        for (i, seg) in clip.texts.enumerated() where i > 0 {
            let sx = xCoord(ms: seg.startMs, w: w, clip: clip)
            let d  = abs(startX - sx)
            if d < nearestSplitDist { nearestSplitDist = d; nearestSplitIndex = i }
        }

        if nearestHandleDist <= handleHit && nearestHandleDist <= nearestSplitDist {
            return dLeft <= dRight ? .trimLeft(grabOffset: startX - leftX) : .trimRight(grabOffset: startX - rightX)
        } else if let splitIdx = nearestSplitIndex, nearestSplitDist <= handleHit {
            let splitX = xCoord(ms: clip.texts[splitIdx].startMs, w: w, clip: clip)
            return .splitMove(index: splitIdx, grabOffset: startX - splitX)
        } else {
            return .pendingBody(downX: startX)
        }
    }

    /// 端のつまみをドラッグしている間、指の位置をトリム開始・終了位置へ変換して反映する。
    /// 左右で動かす境界・クランプ範囲が逆になるだけで、やっていることは対称。
    ///
    /// 以前はピクセル位置自体をキャンバス内（[handleW, w-handleW]）へ押し込めていたため、
    /// 今ズームして見えている範囲の端でつまみが止まってしまい、それ以上トリム位置を
    /// 動かせなかった（実際にはまだ動画の前後に伸ばせる余地があっても）。ピクセルの
    /// クランプはやめてmsレベルのクランプだけにし、代わりにpanViewportIfNeededで
    /// 「今ロックされているビューポートの外へ出た分だけビューポート自体をパンする」
    /// ことで、指を動かし続ける限り波形がスクロールして追従するようにする。
    private func dragTrimHandle(isLeft: Bool, grabOffset: CGFloat, loc: CGFloat, w: CGFloat, clip: VlogClip) {
        let rawX = loc - grabOffset
        panViewportIfNeeded(atRawX: rawX, w: w, clip: clip)
        let ms = msAt(x: rawX, w: w, clip: clip)
        let newMs = clampTrimHandleMs(isLeft: isLeft, ms: ms, clip: clip)
        if isLeft {
            store.updateTrim(startMs: newMs, endMs: clip.endMs)
            playerManager.seek(to: newMs)
            playerManager.updateTrimBounds(startMs: newMs, endMs: clip.endMs)
        } else {
            store.updateTrim(startMs: clip.startMs, endMs: newMs)
            playerManager.seek(to: newMs)
            playerManager.updateTrimBounds(startMs: clip.startMs, endMs: newMs)
        }
        updateEdgePinState(x: rawX, w: w)
    }

    /// つまみ（開始/終了）を動かした先の候補[ms]を、動画の範囲・minTrimMsの制約へ
    /// クランプする。指でドラッグしているとき（dragTrimHandle）と、端に張り付いたまま
    /// 自動で進めるとき（advanceEdgeScrollTrimHandle）の両方から呼ぶことで、境界の扱いが
    /// 2箇所でずれないようにする（Android版WaveformTrimmerGestures.ktのclampHandleMsと同じ考え方）。
    private func clampTrimHandleMs(isLeft: Bool, ms: Int64, clip: VlogClip) -> Int64 {
        if isLeft {
            return max(0, min(clip.endMs - VlogClip.minTrimMs, ms))
        } else {
            return max(clip.startMs + VlogClip.minTrimMs, min(clip.durationMs, ms))
        }
    }

    /// 指を止めたまま画面端に張り付いている間も波形が動き続けるようにする（Android版も同様）。
    /// panViewportIfNeededは「ドラッグイベントが来た瞬間だけ」指の位置に応じて反応するため、
    /// 指を動かさなくなるとそこで釣り合って止まってしまう。ここでは別に、いま画面端の
    /// 判定ゾーン内にいるかどうかだけを記録し、下のedgeScrollTaskが一定間隔で
    /// その状態を見てビューポート／トリム値を少しずつ進め続ける
    private func updateEdgePinState(x: CGFloat, w: CGFloat) {
        isPinnedAtLeftEdge  = x <= handleW + edgeScrollZone
        isPinnedAtRightEdge = x >= w - handleW - edgeScrollZone
        startEdgeScrollTaskIfNeeded()
    }

    private func startEdgeScrollTaskIfNeeded() {
        guard edgeScrollTask == nil else { return }
        edgeScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 16_000_000) // 約60fps
                guard !Task.isCancelled else { break }
                guard isPinnedAtLeftEdge || isPinnedAtRightEdge,
                      let clip = store.selectedClip else { continue }
                let direction: Int64 = isPinnedAtLeftEdge ? -1 : 1
                switch drag {
                case .trimLeft:
                    advanceEdgeScrollTrimHandle(isLeft: true, direction: direction, clip: clip)
                case .trimRight:
                    advanceEdgeScrollTrimHandle(isLeft: false, direction: direction, clip: clip)
                case .movingTrim:
                    advanceEdgeScrollMoveTrim(direction: direction, clip: clip)
                default:
                    break
                }
            }
        }
    }

    /// WaveformView.swift本体のonChange(of: store.selectedClip?.id)からも呼ぶためinternal
    func stopEdgeScrollTask() {
        edgeScrollTask?.cancel()
        edgeScrollTask = nil
        isPinnedAtLeftEdge  = false
        isPinnedAtRightEdge = false
    }

    /// 1tickぶんの進む量。今の表示幅（ズーム倍率）の2%ぶん（60fps想定で約1.2倍速/秒）
    /// にしてあり、どれだけズームしていても「張り付いてから追いつくまで」の体感速度が揃う
    private func edgeScrollTickMs(clip: VlogClip) -> Int64 {
        let vp = lockedViewport ?? effectiveViewport(clip: clip)
        let span = max(1, vp.end - vp.start)
        return max(1, Int64(Double(span) * 0.02))
    }

    private func advanceEdgeScrollTrimHandle(isLeft: Bool, direction: Int64, clip: VlogClip) {
        let tickMs = edgeScrollTickMs(clip: clip)
        let candidateMs = (isLeft ? clip.startMs : clip.endMs) + direction * tickMs
        let newMs = clampTrimHandleMs(isLeft: isLeft, ms: candidateMs, clip: clip)
        panViewportIfNeeded(around: newMs, clip: clip)
        if isLeft {
            store.updateTrim(startMs: newMs, endMs: clip.endMs)
            playerManager.updateTrimBounds(startMs: newMs, endMs: clip.endMs)
        } else {
            store.updateTrim(startMs: clip.startMs, endMs: newMs)
            playerManager.updateTrimBounds(startMs: clip.startMs, endMs: newMs)
        }
    }

    private func advanceEdgeScrollMoveTrim(direction: Int64, clip: VlogClip) {
        let tickMs = edgeScrollTickMs(clip: clip)
        let targetStart = clip.startMs + direction * tickMs
        if let result = store.moveTrim(targetStartMs: targetStart) {
            panViewportIfNeeded(around: result.startMs, clip: clip)
            panViewportIfNeeded(around: result.endMs, clip: clip)
            playerManager.updateTrimBounds(startMs: result.startMs, endMs: result.endMs)
        }
    }

    /// トリムつまみ／区間ごと移動が今ロックされているビューポートの外へ出たら、表示幅
    /// （ズーム倍率）は変えずにビューポート自体を指の位置へ追従させてパンする
    /// （Android版WaveformTrimmerGestures.ktのpanViewportIfNeededと同じ考え方）。
    /// 再フィット（fitViewport）のような再ズーム・再センタリングはしない
    /// （＝操作中に表示が動いて指の下から的がずれる事故を再発させないため）。
    private func panViewportIfNeeded(atRawX rawX: CGFloat, w: CGFloat, clip: VlogClip) {
        guard let locked = lockedViewport else { return }
        let extrapolated = geometry(w: w, viewport: locked).extrapolatedMs(rawX)
        panViewportIfNeeded(around: max(0, min(clip.durationMs, extrapolated)), clip: clip)
    }

    /// panViewportIfNeeded(atRawX:)の共通部分。既に確定したms（区間ごと移動の
    /// クランプ後の値など）を渡してパンさせたいときはこちらを直接使う
    private func panViewportIfNeeded(around ms: Int64, clip: VlogClip) {
        guard let locked = lockedViewport else { return }
        let span = locked.end - locked.start
        if ms < locked.start {
            let newStart = max(0, ms)
            lockedViewport = WaveformViewport(start: newStart, end: newStart + span)
        } else if ms > locked.end {
            let newEnd = min(clip.durationMs, ms)
            lockedViewport = WaveformViewport(start: newEnd - span, end: newEnd)
        }
    }

    /// 分割ラインをドラッグしている間、指の位置を区切り位置へ変換して反映する
    private func dragSplitLine(index: Int, grabOffset: CGFloat, loc: CGFloat, w: CGFloat, clip: VlogClip) {
        let newMs = msAt(x: loc - grabOffset, w: w, clip: clip)
        if let clamped = store.moveSplit(index: index, newAtMs: newMs) {
            playerManager.seek(to: clamped)
        }
    }

    /// 本体を触った直後、動いたと判定できたら従来通りなぞって頭出し（スクラブ）へ切り替える
    /// （Android: dragBodyOrMove）。動かないまま一定時間経過した場合はschedulePendingBodyTimeout
    /// 側で.movingTrimへ切り替える
    private func dragPendingBody(downX: CGFloat, value: DragGesture.Value, w: CGFloat, clip: VlogClip) {
        let movedX = abs(value.location.x - downX)
        let movedY = abs(value.translation.height)
        guard movedX > moveSlop || movedY > moveSlop else { return }
        pendingBodyTask?.cancel(); pendingBodyTask = nil
        let wasPlaying = playerManager.isPlaying
        if wasPlaying { playerManager.pause() }
        drag = .seeking(wasPlaying: wasPlaying)
        dragSeek(loc: value.location.x, w: w, clip: clip)
    }

    /// 波形本体をなぞって頭出し（スクラブ）している間、指の位置へ再生位置を追従させる
    private func dragSeek(loc: CGFloat, w: CGFloat, clip: VlogClip) {
        let seekMs = clip.clampToTrim(msAt(x: loc, w: w, clip: clip))
        playerManager.seek(to: seekMs)
    }

    /// 長押しで区間ごと移動している間、指の位置を区間開始位置へ変換してトリム範囲全体をずらす。
    ///
    /// 以前は「掴んだ瞬間のstart位置＋指の移動量(px→ms換算)」という、タッチダウン時点を
    /// 基準にした差分方式だったが、これは今のビューポート（オートスクロールでパンされ続ける）
    /// を一切見ないため、オートスクロールが指の位置と無関係に区間を進め続けている間に
    /// 指がわずかでも動く（実機のタッチ座標は完全静止していても微小に揺れる）と、
    /// タッチダウン基準の差分が「ほぼ元の位置」を指してしまい、オートスクロールの
    /// 進みを毎フレーム引き戻す→ガタつく、という不具合を起こしていた。
    /// つまみ（dragTrimHandle）と同じ「指からのオフセット（grabOffset）＋現在のビューポート」
    /// 方式に変えることで、オートスクロールでビューポートが動くのと歩調を合わせて
    /// 指が動かなくても一貫した位置が出るようにする。
    private func dragMoveTrim(grabOffset: CGFloat, loc: CGFloat, w: CGFloat, clip: VlogClip) {
        let rawX = loc - grabOffset
        let vp = lockedViewport ?? effectiveViewport(clip: clip)
        let targetStart = geometry(w: w, viewport: vp).extrapolatedMs(rawX)
        if let result = store.moveTrim(targetStartMs: targetStart) {
            // 区間の両端どちらが今のビューポート外に出てもパンできるよう、両方試す
            panViewportIfNeeded(around: result.startMs, clip: clip)
            panViewportIfNeeded(around: result.endMs, clip: clip)
            playerManager.updateTrimBounds(startMs: result.startMs, endMs: result.endMs)
            // clip.clampToTrimは使わない：clipはmoveTrim前の古いstart/endMsのままで、
            // resultが今回動かした後の新しい範囲。ここは必ずresultでクランプする
            let seekMs = max(result.startMs, min(result.endMs, msAt(x: loc, w: w, clip: clip)))
            playerManager.seek(to: seekMs)

            // 区間ごと移動は左右どちらの端がビューポート外に張り付くか分からないので、
            // 実際に描画される位置（パン後のジオメトリでmsToXした位置）で両方判定する
            let panned = geometry(w: w, viewport: lockedViewport ?? effectiveViewport(clip: clip))
            isPinnedAtLeftEdge  = panned.msToX(result.startMs) <= handleW + edgeScrollZone
            isPinnedAtRightEdge = panned.msToX(result.endMs)   >= w - handleW - edgeScrollZone
            startEdgeScrollTaskIfNeeded()
        }
    }

    /// 動かさずに指を離した＝タップとして扱い、その場へ頭出しする
    /// （onDragEndの.pendingBody/.splitMove/.movingTrimの3分岐が共有する処理）
    private func finishTap(at x: CGFloat, w: CGFloat, clip: VlogClip) {
        let seekMs = clip.clampToTrim(msAt(x: x, w: w, clip: clip))
        playerManager.seek(to: seekMs)
    }

    /// 動かさず[longPressSeconds]経過したら「区間ごと移動」へ切り替える（Android: dragBodyOrMove）
    private func schedulePendingBodyTimeout(downX: CGFloat, w: CGFloat) {
        pendingBodyTask?.cancel()
        pendingBodyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(longPressSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard case .pendingBody = drag, let clip = store.selectedClip else { return }
            let wasPlaying = playerManager.isPlaying
            if wasPlaying { playerManager.pause() }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            // 区間開始位置の今の画面上のxと、実際に指を置いた位置との差をgrabOffsetとして
            // 固定する（つまみのgrabOffsetと同じ考え方）。以後はこのオフセットと現在の
            // 指の位置・現在のビューポートだけから区間位置を求める（dragMoveTrim参照）
            let grabOffset = downX - xCoord(ms: clip.startMs, w: w, clip: clip)
            drag = .movingTrim(anchorX: downX, grabOffset: grabOffset, wasPlaying: wasPlaying)
        }
    }
}
