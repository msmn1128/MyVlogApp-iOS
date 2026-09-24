import SwiftUI
import AVFoundation

/// 書き出しと同じ 1920:1080 のキャンバス比率で見せるプレビュー。
///
/// 再生位置（約33msごとに変わる）を読むのは`PreviewCaptionLayer`だけにしてある。
/// ここで読むと、Observationがこのbody全体を依存として記録し、再生中ずっと
/// プレビュー全体（AVPlayerLayerのラッパーを含む）が毎秒30回作り直される。
struct PreviewView: View {
    @Environment(VlogStore.self) private var store
    @Environment(VideoPlayerManager.self) private var playerManager

    var body: some View {
        GeometryReader { geo in
            let canvasSize = geo.size  // already constrained 16:9 by caller
            let scale = canvasSize.height / VlogLayout.canvasHeight

            ZStack {
                Color.black // canvas background

                PlayerLayerView(player: playerManager.player)
                    .frame(width: canvasSize.width, height: canvasSize.height)

                // 焼き込まれる文字とタップ判定はこの葉が持つ（再生位置を読むのもここだけ）
                PreviewCaptionLayer(clip: store.selectedClip, canvas: canvasSize, scale: scale)

                if playerManager.isLoading {
                    Color.black.opacity(0.45)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.5)
                }
            }
            .animation(.default, value: playerManager.isLoading)
            // 折り返さないひとことがキャンバスの外へはみ出して、周りの画面に重ならないよう切る
            .clipped()
        }
    }
}

// MARK: - 再生位置に追従する層

/// ひとこと・撮影時刻の焼き込み文字と、再生/一時停止のタップ判定。
///
/// 再生位置を読むのはこの葉だけ。中身はTextが2つだけなので、毎秒30回作り直されても軽い
/// （Android版が`derivedStateOf`で「表示する文字列」へ絞ってから読んでいるのと同じ狙い）。
private struct PreviewCaptionLayer: View {
    @Environment(VideoPlayerManager.self) private var playerManager

    let clip: VlogClip?
    let canvas: CGSize
    let scale: CGFloat

    var body: some View {
        let positionMs = playerManager.currentTimeMs

        ZStack {
            if let clip {
                // ─── ひとこと: 上下左右中央 ───
                hitokotoOverlay(text: clip.textAt(positionMs: positionMs))

                // ─── タイムスタンプ: 上下中央・右端 ───
                HStack {
                    Spacer()
                    Text(clip.timeText)
                        .font(.custom(VlogFonts.timeFontName, size: VlogLayout.timestampFontSize * scale))
                        .foregroundStyle(.white)
                        .padding(.trailing, VlogLayout.timestampRightPad * scale)
                }
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .contentShape(Rectangle())
        .onTapGesture { playerManager.togglePlayPause() }
        .accessibilityElement()
        .accessibilityIdentifier("preview")
        .accessibilityLabel("プレビュー（タップで再生・一時停止）")
        // 読み上げは人が聞いて分かる形（0:01）にする。
        // 以前はミリ秒の生値をそのまま値にしていたため「1,234」と読まれていた
        // （UIテスト用の目印を、そのまま利用者向けの読み上げにも使ってしまっていた）
        .accessibilityValue(Formatters.durationLabel(ms: positionMs))
        // UIテストが読む生のミリ秒は、別の目印として分けて出す。
        // 波形の再生ヘッドはCanvas描画で外から読めず、再生まわりの振る舞い
        // （終端での頭出し・連続再生の停止）を確かめる手段が他に無いため
        // （MyVlogAppUITests/PlaybackUITests.swift が読む）
        .overlay { PlayheadProbe(positionMs: positionMs) }
    }

    /// UIテストから再生位置をミリ秒で読むためだけの、目に見えない目印。
    ///
    /// 利用者向けの読み上げ（プレビューのaccessibilityValue）は「0:01」という
    /// 人が聞いて分かる形にしたいが、テストはミリ秒の生値で判定したい。
    /// 両立させるために分けてある。DEBUGビルドにしか入らないので、
    /// リリースビルドのVoiceOverに余計な項目が増えることはない。
    private struct PlayheadProbe: View {
        let positionMs: Int64

        var body: some View {
            #if DEBUG
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityIdentifier("playheadMs")
                .accessibilityValue("\(positionMs)")
            #else
            EmptyView()
            #endif
        }
    }

    private func hitokotoOverlay(text: String) -> some View {
        let lines      = VlogLayout.captionLines(text)
        let fontSize   = VlogLayout.hitokotoFontSize * scale
        let lineGap    = VlogLayout.hitokotoLineGap * scale
        let lineHeight = fontSize + lineGap
        // 上下左右中央: Y は canvas 中心から均等に配置（ExportWorker+Drawing.drawHitokotoと
        // 同じ計算をVlogLayout.hitokotoBlockTopに共通化している）
        let startY = VlogLayout.hitokotoBlockTop(
            lineCount: lines.count, canvasHeight: canvas.height, fontSize: fontSize, lineGap: lineGap
        )

        return ZStack {
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                // 高さlineHeightのスロットに収めて中央寄せ（ExportWorker+Drawing.drawHitokotoの
                // slotY + lineH/2 と同じ考え方）。以前はfontSize/2を使っており、
                // 単一行のときだけたまたまキャンバス中央に一致し、書き出し側（lineHeight/2基準）
                // との食い違い（lineGap/2ぶんのズレ）に気付きにくくなっていた。
                let y = startY + CGFloat(idx) * lineHeight + lineHeight / 2
                if !line.isEmpty {
                    Text(line)
                        .font(.custom(VlogFonts.logoTypeName, size: fontSize))
                        .foregroundStyle(.white)
                        // 折り返さない。書き出し（drawHitokoto）は1行を実寸のまま中央へ描き、
                        // キャンバスより長ければ左右均等にはみ出す。プレビューだけキャンバス幅で
                        // 折り返すと、画面では収まって見えるのに書き出した動画では左右が切れる
                        // （Android: PreviewSection.ktのsoftWrap = false）
                        .fixedSize()
                        .position(x: canvas.width / 2, y: y)
                }
            }
        }
    }
}
