import SwiftUI
import AVFoundation

struct WaveformView: View {
    // store/playerManagerはWaveformGestures.swiftのextensionからも使うためprivateを外してある
    @Environment(VlogStore.self) var store
    @Environment(VideoPlayerManager.self) var playerManager
    @Environment(ExportManager.self) private var exportManager
    @Environment(\.colorScheme) var colorScheme

    /// nilは「取得できなかった」。読み込み中かどうかはisLoadingで別に持つ
    /// （Android: SelectedWaveform の waveform / isLoading と同じ持ち方）
    @State private var waveform:  Waveform? = nil
    @State private var isLoading: Bool      = false
    // drag以下、ジェスチャー処理本体はWaveformGestures.swiftへ切り出してある。
    // そちらのextensionから読み書きするためprivateを外し、ファイル内既定のinternalにしてある
    // （ContentView.swiftのphotoItems等、ContentView+Import.swiftとの分割と同じ方式）。
    @State var drag: ActiveDrag = .none
    @State var pendingBodyTask: Task<Void, Never>? = nil
    // 波形の表示範囲（ズーム）。長い動画で短くトリムすると、つまみが端に寄って
    // 操作しづらくなるのを防ぐため選択範囲＋余白へズームする（Android: fitWaveformViewport）。
    // @StateにキャッシュしてonChangeで追従させる方式は更新の抜け漏れが起きやすかったため、
    // 「ドラッグ中でなければ毎回computedで出し直す」方式にしている。ドラッグ中だけ
    // ここに値を入れて据え置く（掴んだ瞬間の表示から指の下の的がズレないように）。
    @State var lockedViewport: WaveformViewport? = nil
    // 描画専用のズーム範囲。指を離した瞬間のリフィットが一瞬でパッと切り替わり、
    // 直前まで見えていた位置と無関係な場所へ枠が飛んだように見えるのを防ぐため、
    // 実際のヒットテスト（xCoord/msAt）とは別に、描画だけこの値を滑らかに追従させる。
    // ドラッグ中はlockedViewportと常に同値なので実質アニメーションは発生せず、
    // ドラッグ終了時（isDragIdleがfalse→trueに切り替わる瞬間）だけ計算し直した
    // 新しいfitWaveformViewportへイーズさせる。
    @State private var displayViewport: WaveformViewport? = nil
    // 指を動かさなくても、つまみ／区間ごと移動が画面端に張り付いている間は
    // 波形が自動でスクロールし続けるようにするための状態。
    // panViewportIfNeeded（ドラッグイベントが来た瞬間だけ反応する）とは別に、
    // 「今どちらの端に張り付いているか」をここに持っておき、下のedgeScrollTaskが
    // 一定間隔でそれを見て、指の動きとは無関係に少しずつビューポートと
    // トリム値を進める
    @State var isPinnedAtLeftEdge  = false
    @State var isPinnedAtRightEdge = false
    @State var edgeScrollTask: Task<Void, Never>? = nil
    let edgeScrollZone: CGFloat = 24

    enum ActiveDrag {
        case none
        case trimLeft(grabOffset: CGFloat)
        case trimRight(grabOffset: CGFloat)
        case splitMove(index: Int, grabOffset: CGFloat)
        /// 本体を触った直後：動くか、長押しタイムアウトが来るまで様子見（Android: dragBodyOrMove）
        case pendingBody(downX: CGFloat)
        case seeking(wasPlaying: Bool)
        case movingTrim(anchorX: CGFloat, grabOffset: CGFloat, wasPlaying: Bool)
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

    /// いまドラッグしている区切りの`texts`上の添字（Android: activeSplitIndex）。
    /// 掴んでいる線を太く描いて、どれを動かしているのか指の下からでも分かるようにする
    private var activeSplitIndex: Int? {
        if case .splitMove(let index, _) = drag { return index }
        return nil
    }

    // つまみを掴んだ瞬間に太さが一段階で切り替わらないよう、太さそのものを補間する
    // （Android版WaveformTrimmerのstartHandleScale/endHandleScaleと同じ狙い）。
    // CanvasはSwiftUIのアニメーション機構と直接つながらないため、Animatableな
    // 透明ビュー（HandleScaleAnimator）を経由してアニメーション中の値を毎フレーム
    // 取り出し、Canvasが読むための@Stateへ橋渡ししている。
    @State private var leftHandleScale:  CGFloat = 1
    @State private var rightHandleScale: CGFloat = 1

    /// 区間番号バッジの中心を、上端からどれだけ下げるか（badgesOverlay）。
    /// 文字サイズ設定でバッジ自体が大きくなるので、位置も一緒に下げないと上がはみ出る
    @ScaledMetric(relativeTo: .body) private var badgeCenterY: CGFloat = 10

    private var isDragIdle: Bool {
        if case .none = drag { return true }
        return false
    }

    // handleW/handleHit/moveSlop/longPressSecondsはWaveformGestures.swiftからも参照するためinternal
    let handleW:    CGFloat = 12
    let handleHit:  CGFloat = 28
    private let railH:      CGFloat = 3
    let moveSlop:   CGFloat = 8
    let longPressSeconds: Double = 0.5

    var body: some View {
        GeometryReader { geo in
            let sz = geo.size
            ZStack {
                // 波形・桟・区切り・つまみ。再生位置は読まないので、再生中に描き直されない
                Canvas { ctx, size in
                    drawWaveform(ctx: ctx, size: size)
                }
                .drawingGroup()

                // 再生ヘッドだけ別のCanvasに分ける。
                // 1枚で描いていた頃は、再生位置が変わるたびに波形の棒（長い動画では
                // 最大6000本）ごと毎秒30回描き直していた。線と丸だけの層に分ければ、
                // 再生中に描き直されるのはこちらだけで済む。
                // ドラッグ中は、プレビュー用のシークで再生ヘッドがつまみとほぼ同じ位置に
                // 居続けて操作の邪魔になるため、そもそも描かない
                if !isLeftHandleActive && !isRightHandleActive && !isMovingTrim,
                   let clip = store.selectedClip {
                    PlayheadLayer(
                        clip: clip,
                        viewport: displayViewport ?? effectiveViewport(clip: clip),
                        handleW: handleW,
                        railH: railH,
                        color: AppColors.tertiary(colorScheme)
                    )
                }

                // Split-line number badges (SwiftUI overlay for crisp text)
                if let clip = store.selectedClip {
                    badgesOverlay(clip: clip, size: sz)
                }

                // 波形が出せないときの注記。つまみと桟は描いたままにしてあるので、
                // 読み込みが終わっていなくてもトリミングはできる（Android: WaveformNote）
                waveformNote

                // Canvas描画のハンドル太さをアニメーションさせるための透明な橋渡し役
                CanvasValueAnimator(value: isLeftHandleActive ? 1.35 : 1) { leftHandleScale = $0 }
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isLeftHandleActive)
                CanvasValueAnimator(value: isRightHandleActive ? 1.35 : 1) { rightHandleScale = $0 }
                    .animation(.spring(response: 0.2, dampingFraction: 0.6), value: isRightHandleActive)

                // 表示ズームをdisplayViewportへ滑らかに追従させる透明な橋渡し役。
                // ドラッグ中はeffectiveViewportがlockedViewportのまま変化しないため
                // 実質何も起きず、ドラッグ終了（isDragIdle: false→true）の瞬間だけ
                // 新しいfitWaveformViewportへイーズする
                if let clip = store.selectedClip {
                    let vp = effectiveViewport(clip: clip)
                    CanvasValueAnimator(value: AnimatablePair(Double(vp.start), Double(vp.end))) { pair in
                        displayViewport = WaveformViewport(start: Int64(pair.first), end: Int64(pair.second))
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
            // 書き出し中はトリムも区切りも動かさせない（Android: WaveformTrimmer の enabled）
            .allowsHitTesting(!exportManager.isExporting)
            // 波形はCanvasで描いているので、つまみも区切りも再生ヘッドも
            // VoiceOverからは一切見えない（Canvasは中の要素を支援技術へ出さない）。
            // 同じ操作を「調整できる項目」として別に用意する（accessibilityControls）
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("波形。トリム範囲とひとことの区切りを調整できます")
            .accessibilityChildren { accessibilityControls }
        }
        .task(id: store.selectedClip?.id) { await loadWaveform() }
        .onChange(of: store.selectedClip?.id) { _, _ in
            stopEdgeScrollTask()
            lockedViewport = nil
            displayViewport = nil
        }
    }

    // MARK: - VoiceOver（Canvasの中身は支援技術から見えないため、別に用意する）

    /// 波形のかわりにVoiceOverへ出す操作項目。
    ///
    /// `accessibilityChildren`に渡したビューは画面には描かれず、支援技術向けの
    /// 要素を作るためだけに使われる（Appleのドキュメントが示すCanvasの定石）。
    /// ドラッグでしかできなかったトリムと頭出しを、上下スワイプ（調整）で行えるようにする。
    @ViewBuilder
    private var accessibilityControls: some View {
        if let clip = store.selectedClip, !exportManager.isExporting {
            VStack {
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel("トリム開始")
                    .accessibilityValue(Formatters.durationLabel(ms: clip.startMs))
                    .accessibilityHint("上下スワイプで、切り出しの開始位置を動かします")
                    .accessibilityAdjustableAction { direction in
                        adjustTrimStart(by: step(for: clip, direction: direction))
                    }

                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel("トリム終了")
                    .accessibilityValue(Formatters.durationLabel(ms: clip.endMs))
                    .accessibilityHint("上下スワイプで、切り出しの終了位置を動かします")
                    .accessibilityAdjustableAction { direction in
                        adjustTrimEnd(by: step(for: clip, direction: direction))
                    }

                // 範囲ごと移動と区切りの移動も、指では長押し・ドラッグでしかできなかった
                // （Android: trimmerActions の「範囲ごと」「区切りN」）
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel("範囲ごと移動")
                    .accessibilityValue(
                        "\(Formatters.durationLabel(ms: clip.startMs))〜\(Formatters.durationLabel(ms: clip.endMs))"
                    )
                    .accessibilityHint("上下スワイプで、長さはそのままに使う範囲を前後へ動かします")
                    .accessibilityAdjustableAction { direction in
                        moveTrimRange(by: step(for: clip, direction: direction))
                    }

                ForEach(Array(clip.texts.indices.dropFirst()), id: \.self) { index in
                    Color.clear
                        .accessibilityElement()
                        .accessibilityLabel("ひとことの区切り\(index)")
                        .accessibilityValue(Formatters.durationLabel(ms: clip.texts[index].startMs))
                        .accessibilityHint("上下スワイプで、区切りの位置を前後に動かします")
                        .accessibilityAdjustableAction { direction in
                            moveSplit(index: index, by: step(for: clip, direction: direction))
                        }
                }

                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel("再生位置")
                    .accessibilityValue(Formatters.durationLabel(ms: playerManager.currentTimeMs))
                    .accessibilityHint("上下スワイプで、再生位置を前後に動かします")
                    .accessibilityAdjustableAction { direction in
                        adjustPlayhead(by: step(for: clip, direction: direction), clip: clip)
                    }
            }
        }
    }

    /// 上下スワイプ1回で動かす量（計算はModels.swiftの純粋関数側にある）
    private func step(for clip: VlogClip, direction: AccessibilityAdjustmentDirection) -> Int64 {
        let magnitude = accessibilityAdjustStepMs(durationMs: clip.durationMs)
        return direction == .increment ? magnitude : -magnitude
    }

    private func adjustTrimStart(by deltaMs: Int64) {
        guard let clip = store.selectedClip else { return }
        let newStart = adjustedTrimStartMs(clip: clip, deltaMs: deltaMs)
        guard newStart != clip.startMs else { return }
        store.updateTrim(startMs: newStart, endMs: clip.endMs)
        // 終端の監視の張り直しはContentViewがtrimBoundsのonChangeで面倒を見る。
        // 指で動かすときと同じく止めて、動かした端のコマを出す
        playerManager.pause()
        playerManager.seek(to: newStart)
    }

    private func adjustTrimEnd(by deltaMs: Int64) {
        guard let clip = store.selectedClip else { return }
        let newEnd = adjustedTrimEndMs(clip: clip, deltaMs: deltaMs)
        guard newEnd != clip.endMs else { return }
        store.updateTrim(startMs: clip.startMs, endMs: newEnd)
        playerManager.pause()
        playerManager.seek(to: newEnd)
    }

    private func moveTrimRange(by deltaMs: Int64) {
        guard let clip = store.selectedClip,
              let moved = store.moveTrim(targetStartMs: clip.startMs + deltaMs),
              moved.startMs != clip.startMs else { return }
        playerManager.pause()
        playerManager.seek(to: moved.startMs)
    }

    private func moveSplit(index: Int, by deltaMs: Int64) {
        guard let clip = store.selectedClip, clip.texts.indices.contains(index),
              let moved = store.moveSplit(index: index, newAtMs: clip.texts[index].startMs + deltaMs)
        else { return }
        playerManager.pause()
        playerManager.seek(to: moved)
    }

    private func adjustPlayhead(by deltaMs: Int64, clip: VlogClip) {
        playerManager.seek(to: clip.clampToTrim(playerManager.currentTimeMs + deltaMs))
    }

    // MARK: - Coordinate helpers
    // The time axis occupies [handleW, w-handleW] so handles never overflow.
    // ms は絶対時間、表示は effectiveViewport() のズーム範囲にマッピングする。

    /// ドラッグ中はlockedViewportを据え置き、そうでなければ選択範囲から毎回計算し直す
    /// （Android: WaveformTrimmerGestures.kt内、操作中はSideEffectで据え置き、そうでなければ
    /// 毎コンポジションで出し直す方式と同じ。以前はAndroid側もLaunchedEffect(...isInteracting)の
    /// onChange発火漏れという課題を抱えていたが、現在はどちらも「キャッシュを信じず常に
    /// 最新のclipから出し直す」設計に揃っている）。
    /// WaveformGestures.swiftからも参照するためinternal。
    func effectiveViewport(clip: VlogClip) -> WaveformViewport {
        if let locked = lockedViewport, !isDragIdle { return locked }
        return WaveformGeometry.fitViewport(startMs: clip.startMs, endMs: clip.endMs, durationMs: clip.durationMs)
    }

    func geometry(w: CGFloat, viewport: WaveformViewport) -> WaveformGeometry {
        WaveformGeometry.forWidth(w, handleW: handleW, viewport: viewport)
    }

    func xCoord(ms: Int64, w: CGFloat, clip: VlogClip) -> CGFloat {
        geometry(w: w, viewport: effectiveViewport(clip: clip)).msToX(ms)
    }

    /// 描画専用：ヒットテストとは別に、displayViewportで滑らかに追従した位置を返す
    private func displayXCoord(ms: Int64, w: CGFloat, clip: VlogClip) -> CGFloat {
        geometry(w: w, viewport: displayViewport ?? effectiveViewport(clip: clip)).msToX(ms)
    }

    func msAt(x: CGFloat, w: CGFloat, clip: VlogClip) -> Int64 {
        geometry(w: w, viewport: effectiveViewport(clip: clip)).xToMs(x, durationMs: clip.durationMs)
    }

    // MARK: - Canvas drawing

    private func drawWaveform(ctx: GraphicsContext, size: CGSize) {
        guard let clip = store.selectedClip else { return }
        let w = size.width
        let h = size.height
        let vp  = displayViewport ?? effectiveViewport(clip: clip)
        let geo = geometry(w: w, viewport: vp)
        let leftX  = geo.msToX(clip.startMs)
        let rightX = geo.msToX(clip.endMs)

        // 各描画パートはWaveformDrawing.swiftの純粋関数に切り出してある
        // （Android: WaveformTrimmer.kt / WaveformTrimmerDrawing.ktと同じ分離）
        drawWaveformBars(ctx: ctx, geo: geo, waveform: waveform, height: h, railH: railH,
                          durationMs: clip.durationMs, trimLeftX: leftX, trimRightX: rightX,
                          dimColor: AppColors.waveformDim)
        drawTrimRails(ctx: ctx, leftX: leftX, rightX: rightX, height: h, railH: railH, isMovingTrim: isMovingTrim)
        // 動画は切っていないので、ひとことの切れ目は自分で描かないと分からない。
        // 区切りが1つも無いクリップでは描かない（Android: if (texts.size > 1)）
        if clip.texts.count > 1 {
            drawSplitLines(ctx: ctx, geo: geo, texts: clip.texts, height: h,
                           activeIndex: activeSplitIndex, color: AppColors.splitLine(colorScheme))
        }
        let gripColor = AppColors.onPrimary(colorScheme)
        drawTrimHandle(ctx: ctx, x: leftX,  height: h, handleW: handleW, isLeft: true,
                       scale: leftHandleScale,  gripColor: gripColor)
        drawTrimHandle(ctx: ctx, x: rightX, height: h, handleW: handleW, isLeft: false,
                       scale: rightHandleScale, gripColor: gripColor)
        // 再生ヘッドはここでは描かない（PlayheadLayerが別のCanvasで描く）。
        // 一緒に描くと、再生位置が変わるたびに波形の棒ごと描き直すことになる
    }

    // MARK: - 再生ヘッド（別レイヤー）

    /// 再生ヘッドだけを描く層。再生位置を読むのはここだけ。
    ///
    /// 波形本体と同じCanvasに描いていた頃は、再生位置が変わるたびに棒（長い動画では
    /// 最大6000本）ごと描き直していた。線と丸だけならCanvasを分けたほうが安い
    /// （Android版が再生位置を`State<Long>`のまま渡し、描画フェーズでだけ読んでいるのと同じ狙い）。
    private struct PlayheadLayer: View {
        @Environment(VideoPlayerManager.self) private var playerManager

        let clip: VlogClip
        let viewport: WaveformViewport
        let handleW: CGFloat
        let railH: CGFloat
        let color: Color

        var body: some View {
            let positionMs = playerManager.currentTimeMs
            Canvas { ctx, size in
                let geo = WaveformGeometry.forWidth(size.width, handleW: handleW, viewport: viewport)
                drawPlayhead(ctx: ctx, geo: geo, positionMs: positionMs, clip: clip,
                             height: size.height, railH: railH, color: color)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - 波形が出せないときの注記

    /// 読み込み中／取得できなかった／音声なし を出し分ける（Android: WaveformTrimmerの when 節）。
    /// 以前はスピナーだけで、取得失敗と音声なしがどちらも「平らな波形」に見えていた。
    @ViewBuilder
    private var waveformNote: some View {
        if isLoading {
            noteBackground {
                ProgressView()
                    .controlSize(.mini)
                    .tint(AppColors.primary)
                noteText("波形を読み込み中…")
            }
        } else if waveform == nil {
            noteBackground { noteText("波形を取得できませんでした") }
        } else if waveform?.hasAudio == false {
            noteBackground { noteText("音声なし") }
        }
    }

    private func noteBackground<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6, content: content)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.card(colorScheme).opacity(0.9))
            )
    }

    private func noteText(_ text: String) -> some View {
        Text(text)
            .vlogFont(11)
            .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
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
                            .vlogFont(9, weight: .bold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(splitColor)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            // 上端からの位置も文字サイズ設定に合わせて下げる。
                            // .position()は中心を指定するので、10のままだと大きい文字設定で
                            // バッジの上半分が波形の外へはみ出して切れる
                            .position(x: min(max(anchorX, 0), w - 10) + 10, y: badgeCenterY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: - Waveform loading

    private func loadWaveform() async {
        guard let clip = store.selectedClip else {
            waveform  = nil
            isLoading = false
            return
        }
        isLoading = true
        waveform  = nil
        // どの経路で抜けてもスピナーを下ろす。以前は早期returnの経路で立てっぱなしになり、
        // 全クリップを削除してから足し直すと「読み込み中」が消えないことがあった
        defer { isLoading = false }

        do {
            let asset = try await AssetLoader.shared.load(clip: clip, forPreview: true)
            let data  = await WaveformExtractor.shared.extract(
                asset: asset, cacheKey: clip.mediaCacheKey, durationMs: clip.durationMs
            )
            // 待っている間に別のクリップへ切り替わっていたら、その結果は捨てる
            // （切り替え先の.taskがもう走っているので、そちらが自分の結果を入れる）
            guard store.selectedClip?.id == clip.id else { return }
            waveform = data
        } catch {
            guard store.selectedClip?.id == clip.id else { return }
            waveform = nil   // 読めなかった＝「波形を取得できませんでした」
        }
    }
}

