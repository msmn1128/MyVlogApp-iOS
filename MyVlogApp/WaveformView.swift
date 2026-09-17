import SwiftUI
import AVFoundation

struct WaveformView: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager
    @Environment(\.colorScheme) var colorScheme

    @State private var waveform:  [Float] = []
    @State private var isLoading: Bool    = false
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
        }
        .task(id: store.selectedClip?.id) { await loadWaveform() }
        .onChange(of: store.selectedClip?.id) { _, _ in
            stopEdgeScrollTask()
            lockedViewport = nil
            displayViewport = nil
        }
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
        let bins = waveform.isEmpty ? Array(repeating: Float(0.08), count: 240) : waveform
        drawWaveformBars(ctx: ctx, geo: geo, bins: bins, height: h, railH: railH,
                          durationMs: clip.durationMs, trimLeftX: leftX, trimRightX: rightX)
        drawTrimRails(ctx: ctx, leftX: leftX, rightX: rightX, height: h, railH: railH, isMovingTrim: isMovingTrim)
        drawSplitLines(ctx: ctx, geo: geo, splitPoints: clip.splitPoints, height: h, railH: railH,
                       color: AppColors.splitLine(colorScheme))
        drawTrimHandle(ctx: ctx, x: leftX,  height: h, handleW: handleW, isLeft: true,  scale: leftHandleScale)
        drawTrimHandle(ctx: ctx, x: rightX, height: h, handleW: handleW, isLeft: false, scale: rightHandleScale)
        // トリムつまみ／区間ごと移動のドラッグ中は、プレビュー用のシークで再生位置が
        // つまみとほぼ同じ位置になり続け、白い再生ヘッドのピンがつまみに重なって
        // 操作の邪魔に見える（特に端でのオートスクロール中は目立つ）。ドラッグ中は
        // 再生ヘッドの表示自体を止めて、動かしている対象（つまみ／区間全体）だけが
        // はっきり見えるようにする
        if !isLeftHandleActive && !isRightHandleActive && !isMovingTrim {
            drawPlayhead(ctx: ctx, geo: geo, positionMs: playerManager.currentTimeMs, clip: clip, height: h, railH: railH)
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

    // MARK: - Waveform loading

    private func loadWaveform() async {
        guard let clip = store.selectedClip else { waveform = []; return }
        await MainActor.run { isLoading = true; waveform = [] }
        do {
            let asset = try await AssetLoader.shared.load(clip: clip, forPreview: true)
            let data  = await WaveformExtractor.shared.extract(asset: asset, clipID: clip.id)
            await MainActor.run { waveform = data; isLoading = false }
        } catch {
            await MainActor.run { isLoading = false }
        }
    }
}

