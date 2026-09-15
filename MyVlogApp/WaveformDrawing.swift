import SwiftUI

// =====================================================================================
// WaveformView.swiftからの切り出し。波形トリマーのCanvas描画部分だけをまとめたもの。
// ジェスチャー判定（ヒットテスト・ドラッグ処理）とは独立した純粋な描画処理で、
// 読み取り専用の引数だけを受け取るため、単独ファイルへ置ける
// （Android: WaveformTrimmerDrawing.ktと同じ切り出し方）。
// =====================================================================================

/// 波形の棒。
/// 各バーは「クリップ全体」を均等に分けた時間幅を受け持つ。以前はこの時間幅を
/// 無視してキャンバス全幅へ均等に敷き詰めていたため、つまみ（枠）だけが
/// ズーム後の位置へ移動する一方で波形の絵そのものは動かず、「枠が波形と無関係な
/// 場所へ飛んだ」ように見えていた。各バーの中心時刻をgeo.msToXでズーム後の位置へ
/// 変換して描く（ズーム範囲外のバーは間引く）ことで、つまみだけでなく波形の絵
/// 自体がズームするようにする（Android: drawWaveformBars/TrackMetrics.msToX）。
func drawWaveformBars(
    ctx: GraphicsContext, geo: WaveformGeometry, bins: [Float],
    height: CGFloat, railH: CGFloat, durationMs: Int64,
    trimLeftX: CGFloat, trimRightX: CGFloat
) {
    let midY   = height / 2
    let maxAmp = (height - railH * 2 - 2) / 2
    let bucketMs = CGFloat(max(1, durationMs)) / CGFloat(bins.count)
    let barW     = max(1, bucketMs * geo.pxPerMs * 0.68)

    for (i, amp) in bins.enumerated() {
        let bucketCenterMs = Int64((CGFloat(i) + 0.5) * bucketMs)
        let barCenter = geo.msToX(bucketCenterMs)
        guard barCenter >= geo.left - barW && barCenter <= geo.right + barW else { continue }
        let amplitude = CGFloat(amp) * maxAmp
        let barRect   = CGRect(x: barCenter - barW / 2, y: midY - amplitude,
                                width: barW, height: amplitude * 2)
        let inRange   = barCenter >= trimLeftX && barCenter <= trimRightX
        ctx.fill(Path(roundedRect: barRect, cornerRadius: barW / 2),
                 with: .color(inRange ? AppColors.waveformFill : AppColors.waveformDim))
    }
}

/// 選択範囲を囲う上下の桟。区間ごと移動中は太くする（Android: isMovingTrim）
func drawTrimRails(
    ctx: GraphicsContext, leftX: CGFloat, rightX: CGFloat,
    height: CGFloat, railH: CGFloat, isMovingTrim: Bool
) {
    let trimW = rightX - leftX
    let activeRailH = isMovingTrim ? railH + 2 : railH
    ctx.fill(Path(CGRect(x: leftX, y: 0, width: trimW, height: activeRailH)), with: .color(AppColors.primary))
    ctx.fill(Path(CGRect(x: leftX, y: height - activeRailH, width: trimW, height: activeRailH)), with: .color(AppColors.primary))
}

/// ひとことの区切り線。
/// Android版drawSegmentSplitsはトリム範囲外の区切りも（ビューポート内である限り）
/// そのまま描く。トリムを動かせばまた見える位置なので隠す理由がない
func drawSplitLines(
    ctx: GraphicsContext, geo: WaveformGeometry, splitPoints: [Int64],
    height: CGFloat, railH: CGFloat, color: Color
) {
    for splitMs in splitPoints {
        let sx = geo.msToX(splitMs)
        var path = Path()
        path.move(to: CGPoint(x: sx, y: railH + 1))
        path.addLine(to: CGPoint(x: sx, y: height - railH - 1))
        ctx.stroke(path, with: .color(color), lineWidth: 2)
    }
}

/// 縦長の丸ピル＋中央の滑り止め3本のトリムつまみ。
/// 掴んでいる側は太さそのものをscaleぶん大きくする。トリム境界に接する辺
/// （左つまみなら右辺、右つまみなら左辺）は動かさず、外側へだけ広がるようにする
func drawTrimHandle(
    ctx: GraphicsContext, x: CGFloat, height: CGFloat,
    handleW: CGFloat, isLeft: Bool, scale: CGFloat
) {
    let w    = handleW * scale
    let rx   = isLeft ? x - w : x
    let rect = CGRect(x: rx, y: 0, width: w, height: height)
    ctx.fill(Path(roundedRect: rect, cornerRadius: 3 * scale), with: .color(AppColors.primary))
    let midX = rx + w / 2
    for dy: CGFloat in [-5, 0, 5] {
        var grip = Path()
        grip.move(to: CGPoint(x: midX - 2.5, y: height / 2 + dy))
        grip.addLine(to: CGPoint(x: midX + 2.5, y: height / 2 + dy))
        ctx.stroke(grip, with: .color(.white.opacity(0.7)), lineWidth: 1.5)
    }
}

/// 再生ヘッド。
/// Android版と同じく、再生位置が今のビューポート外／トリム範囲外なら
/// 頭出し位置へクランプして描くのではなく、そもそも描かない
func drawPlayhead(
    ctx: GraphicsContext, geo: WaveformGeometry, positionMs: Int64,
    clip: VlogClip, height: CGFloat, railH: CGFloat
) {
    guard positionMs >= geo.viewport.start && positionMs <= geo.viewport.end,
          positionMs >= clip.startMs && positionMs <= clip.endMs else { return }
    let playX = geo.msToX(positionMs)
    var headPath = Path()
    headPath.move(to: CGPoint(x: playX, y: railH + 1))
    headPath.addLine(to: CGPoint(x: playX, y: height - railH - 1))
    ctx.stroke(headPath, with: .color(.white), lineWidth: 2)
    ctx.fill(Path(ellipseIn: CGRect(x: playX - 5, y: railH, width: 10, height: 10)),
             with: .color(.white))
}
