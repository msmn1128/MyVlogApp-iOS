import CoreGraphics

/// 波形の表示ズーム範囲。以前は`WaveformView`内で`(start: Int64, end: Int64)`という
/// タプルだったが、名前付き型にしてEquatableを得ることでCanvasValueAnimator/onChangeから
/// 素直に扱えるようにする。
struct WaveformViewport: Equatable {
    var start: Int64
    var end:   Int64
}

/// px⇔ms変換を1か所に集約したもの（Android: WaveformTrimmerGestures.ktのTrackMetrics相当）。
/// ジェスチャー処理・Canvas描画のどちらからも、同じ変換ロジックを通して座標を扱う。
struct WaveformGeometry {
    let left:  CGFloat
    let right: CGFloat
    let viewport: WaveformViewport

    var width:  CGFloat { max(1, right - left) }
    var spanMs: Int64   { max(1, viewport.end - viewport.start) }
    var pxPerMs: CGFloat { width / CGFloat(spanMs) }

    func msToX(_ ms: Int64) -> CGFloat {
        left + (CGFloat(ms) - CGFloat(viewport.start)) / CGFloat(spanMs) * width
    }

    /// ⚠️ Android版TrackMetrics.xToMsはビューポート内（viewStartMs...viewEndMs）へ
    /// クランプするが、iOS版は元々0...durationMsへクランプする設計だった
    /// （ズーム中に端の挙動が変わるため、ここはAndroidに合わせず既存仕様を維持する）。
    func xToMs(_ x: CGFloat, durationMs: Int64) -> Int64 {
        let raw = CGFloat(viewport.start) + (x - left) / width * CGFloat(spanMs)
        return Int64(max(0, min(CGFloat(durationMs), raw)))
    }

    /// クランプなしでx→msへ線形変換する。トリムつまみ／区間ごと移動が今のビューポート端に
    /// 達したときに「どれだけはみ出しているか」を知るために使う（xToMsと違い
    /// 0...durationMsへもクランプしない）
    func extrapolatedMs(_ x: CGFloat) -> Int64 {
        Int64(CGFloat(viewport.start) + (x - left) / width * CGFloat(spanMs))
    }

    /// つまみの半分ぶん内側に縮めたトラック範囲を作る（左右0%・100%でもつまみが切れないように）
    static func forWidth(_ totalWidth: CGFloat, handleW: CGFloat, viewport: WaveformViewport) -> WaveformGeometry {
        guard totalWidth > 2 * handleW else {
            return WaveformGeometry(left: handleW, right: handleW + 1, viewport: viewport)
        }
        return WaveformGeometry(left: handleW, right: totalWidth - handleW, viewport: viewport)
    }
}

/// 選択範囲が全体の尺のこの割合以上あれば、ズームせず全体表示のままにする。
/// 長い動画の一部だけを選んでいるときだけ拡大したいので、大部分を選んでいる
/// ときにまでズームすると逆に見づらくなる（Android: WAVEFORM_FIT_FULL_THRESHOLD）。
private let fitFullThreshold: Double = 0.6
/// ズーム時、選択範囲の前後に確保する余白（選択範囲の長さに対する比率）
private let fitMarginRatio: Double = 0.5
/// ズーム時に確保する余白の下限。選択範囲が短すぎても手がかりが残るように
private let fitMinMarginMs: Int64 = 300
/// ズーム時の表示幅の下限。選択範囲がごく短くても波形が潰れないように
private let fitMinWindowMs: Int64 = 3_000

extension WaveformGeometry {
    /// 現在の選択範囲(startMs〜endMs)に合わせて波形の表示範囲を決める（Android: fitWaveformViewport）。
    /// 選択範囲が全体の大部分を占めるときは全体表示のまま返し、
    /// 一部分だけを選んでいるときは選択範囲＋余白へズームした範囲を返す。
    /// 呼び出し側はこれをドラッグ中は据え置き、ドラッグの区切り（プリセット適用・
    /// ハンドルを離した瞬間など）でだけ呼び直すことで、操作中に表示が動いて
    /// 掴んでいる指の下から的がずれる事故を避けている。
    static func fitViewport(startMs: Int64, endMs: Int64, durationMs: Int64) -> WaveformViewport {
        guard durationMs > 0 else { return WaveformViewport(start: 0, end: 0) }
        let selectionSpan = max(0, endMs - startMs)
        if Double(selectionSpan) >= Double(durationMs) * fitFullThreshold {
            return WaveformViewport(start: 0, end: durationMs)
        }

        let margin = max(Int64(Double(selectionSpan) * fitMarginRatio), fitMinMarginMs)
        var viewStart = startMs - margin
        var viewEnd   = endMs + margin

        let shortfall = fitMinWindowMs - (viewEnd - viewStart)
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
        return WaveformViewport(start: max(0, viewStart), end: min(durationMs, viewEnd))
    }
}
