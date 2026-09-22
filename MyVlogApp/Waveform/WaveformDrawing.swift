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
/// 棒同士の間隔の下限。これより密になるときは数本をまとめて描く（Android: MIN_BAR_SPACING）
private let minBarSpacing: CGFloat = 1.3

/// 無音の区間でも棒が消えてしまわないよう、最低限の高さを残す（Android: minHalf）
private let minBarHalfHeight: CGFloat = 0.75

func drawWaveformBars(
    ctx: GraphicsContext, geo: WaveformGeometry, waveform: Waveform?,
    height: CGFloat, railH: CGFloat, durationMs: Int64,
    trimLeftX: CGFloat, trimRightX: CGFloat, dimColor: Color
) {
    let midY = height / 2

    // 読み込み中・取得できなかった・音声なしのときは、つまめる範囲が分かるよう
    // 土台の線だけ引く（Android: drawWaveformBarsのelse節）
    guard let amplitudes = waveform.flatMap({ $0.hasAudio ? $0.amplitudes : nil }),
          !amplitudes.isEmpty else {
        var baseline = Path()
        baseline.move(to: CGPoint(x: geo.left, y: midY))
        baseline.addLine(to: CGPoint(x: geo.right, y: midY))
        ctx.stroke(baseline, with: .color(dimColor), lineWidth: 1)
        return
    }

    let maxHalf  = max(height / 2 - 10, minBarHalfHeight)
    let bucketMs = CGFloat(max(1, durationMs)) / CGFloat(amplitudes.count)

    // 長い動画は本数が多く（WaveformExtractor.buckets(forDurationMs:)）、全体表示だと
    // 1本が1px未満になる。棒同士の間隔が一定以上になるよう、密なときだけ隣り合う数本を
    // まとめて最大値の1本として描く。ズームして間隔が空けば step=1 に戻り1本ずつ描く
    let bucketSpacing = bucketMs * geo.pxPerMs
    let step = min(max(Int((minBarSpacing / max(bucketSpacing, 0.0001)).rounded(.up)), 1), amplitudes.count)
    let barW = max(1, bucketSpacing * CGFloat(step) * 0.68)

    var index = 0
    while index < amplitudes.count {
        let groupEnd = min(index + step, amplitudes.count)
        let centerMs = Int64((CGFloat(index + groupEnd) / 2) * bucketMs)
        let barCenter = geo.msToX(centerMs)
        guard barCenter >= geo.left - barW, barCenter <= geo.right + barW else {
            index = groupEnd
            continue
        }
        // まとめるときは最大値を採る（平均だとピークが埋もれて波形が平らに見える）
        let amplitude = amplitudes[index..<groupEnd].max() ?? 0
        index = groupEnd

        let half = max(CGFloat(amplitude) * maxHalf, minBarHalfHeight)
        let barRect = CGRect(x: barCenter - barW / 2, y: midY - half, width: barW, height: half * 2)
        let inRange = barCenter >= trimLeftX && barCenter <= trimRightX
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
/// そのまま描く。トリムを動かせばまた見える位置なので隠す理由がない。
///
/// - Parameter texts: 区切りは2番目以降の区間の頭。`activeIndex`と添字を合わせるため、
///   splitPointsではなくtexts全体を受け取る
/// - Parameter activeIndex: いまドラッグしている区切りの`texts`上の添字。
///   掴んでいる線を太くして、どれを動かしているのか指の下からでも分かるようにする
func drawSplitLines(
    ctx: GraphicsContext, geo: WaveformGeometry, texts: [TextSegment],
    height: CGFloat, activeIndex: Int?, color: Color
) {
    for (index, segment) in texts.enumerated() where index > 0 {
        let sx = geo.msToX(segment.startMs)
        var path = Path()
        // Androidと同じく上下の桟を含めた全高に引く（桟の内側だけだと短く見える）
        path.move(to: CGPoint(x: sx, y: 0))
        path.addLine(to: CGPoint(x: sx, y: height))
        ctx.stroke(path, with: .color(color), lineWidth: index == activeIndex ? 4.5 : 2.5)
    }
}

/// 縦長の丸ピル＋中央の滑り止め2本のトリムつまみ（Android: drawTrimHandle）。
///
/// 掴んでいる側は太さそのものをscaleぶん大きくする。トリム境界に接する辺
/// （左つまみなら右辺、右つまみなら左辺）は動かさず、外側へだけ広がるようにする
/// （ここはAndroid版の「境界を中心に左右へ広がる」形とは意図的に変えてある。
/// つまみが選択範囲の内側へ食い込むと、短くトリムしたときに範囲が隠れてしまうため）。
///
/// 滑り止めの形と寸法はAndroidに合わせた縦2本。以前は横3本で、掴む向き（左右）と
/// 線の向きが噛み合っていなかった。
func drawTrimHandle(
    ctx: GraphicsContext, x: CGFloat, height: CGFloat,
    handleW: CGFloat, isLeft: Bool, scale: CGFloat, gripColor: Color
) {
    let w    = handleW * scale
    let half = w / 2
    let rx   = isLeft ? x - w : x
    let rect = CGRect(x: rx, y: 0, width: w, height: height)
    // cornerRadiusは幅の半分＝両端が半円の「丸ピル」（Android: cornerRadius = half）
    ctx.fill(Path(roundedRect: rect, cornerRadius: half), with: .color(AppColors.primary))

    let midX          = rx + half
    let gripHalfHeight = height * 0.16
    let gripGap        = half * 0.42
    let gripWidth      = max(half * 0.22, 1)
    for dx in [-gripGap, gripGap] {
        let gripRect = CGRect(
            x: midX + dx - gripWidth / 2,
            y: height / 2 - gripHalfHeight,
            width: gripWidth,
            height: gripHalfHeight * 2
        )
        ctx.fill(Path(roundedRect: gripRect, cornerRadius: gripWidth / 2), with: .color(gripColor))
    }
}

/// 再生ヘッド。
/// Android版と同じく、再生位置が今のビューポート外／トリム範囲外なら
/// 頭出し位置へクランプして描くのではなく、そもそも描かない
/// - Parameter color: Android: MaterialTheme.colorScheme.tertiary。primary（紫）と分けて、
///   波形やつまみと同系色にならないようにする（以前は白で、明るい波形に埋もれていた）
func drawPlayhead(
    ctx: GraphicsContext, geo: WaveformGeometry, positionMs: Int64,
    clip: VlogClip, height: CGFloat, railH: CGFloat, color: Color
) {
    guard positionMs >= geo.viewport.start && positionMs <= geo.viewport.end,
          positionMs >= clip.startMs && positionMs <= clip.endMs else { return }
    let playX = geo.msToX(positionMs)
    var headPath = Path()
    headPath.move(to: CGPoint(x: playX, y: railH))
    headPath.addLine(to: CGPoint(x: playX, y: height - railH))
    ctx.stroke(headPath, with: .color(color), lineWidth: 2)
    // 上端の丸で「つまんで動かせる」ことを示す（Android: radius 4dp、中心は railHeight + 4dp）
    let radius: CGFloat = 4
    ctx.fill(
        Path(ellipseIn: CGRect(x: playX - radius, y: railH, width: radius * 2, height: radius * 2)),
        with: .color(color)
    )
}
