import SwiftUI
import AVFoundation

struct PreviewView: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager

    var body: some View {
        GeometryReader { geo in
            let canvasSize = geo.size  // already constrained 16:9 by caller
            let scale = canvasSize.height / VlogLayout.canvasHeight

            ZStack {
                Color.black // canvas background

                PlayerLayerView(player: playerManager.player)
                    .frame(width: canvasSize.width, height: canvasSize.height)

                if let clip = store.selectedClip {
                    overlayContent(clip: clip, canvas: canvasSize, scale: scale)
                }

                if playerManager.isLoading {
                    Color.black.opacity(0.45)
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(1.5)
                }
            }
            .animation(.default, value: playerManager.isLoading)
            .contentShape(Rectangle())
            .onTapGesture { playerManager.togglePlayPause() }
        }
    }

    // MARK: - Overlay text

    private func overlayContent(clip: VlogClip, canvas: CGSize, scale: CGFloat) -> some View {
        let pos          = playerManager.currentTimeMs
        let hitokotoText = clip.textAt(positionMs: pos)
        let timeText     = clip.timeText

        return ZStack {
            // ─── ひとこと: 上下左右中央 ───
            hitokotoOverlay(text: hitokotoText, canvas: canvas, scale: scale)

            // ─── タイムスタンプ: 上下中央・右端 ───
            HStack {
                Spacer()
                Text(timeText)
                    .font(.custom(VlogFonts.timeFontName, size: VlogLayout.timestampFontSize * scale))
                    .foregroundStyle(.white)
                    .padding(.trailing, VlogLayout.timestampRightPad * scale)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .allowsHitTesting(false)
    }

    private func hitokotoOverlay(text: String, canvas: CGSize, scale: CGFloat) -> some View {
        let lines      = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fontSize   = VlogLayout.hitokotoFontSize * scale
        let lineGap    = VlogLayout.hitokotoLineGap * scale
        let lineHeight = fontSize + lineGap
        // 上下左右中央: Y は canvas 中心から均等に配置（ExportManagerのdrawHitokotoと
        // 同じ計算をVlogLayout.hitokotoBlockTopに共通化している）
        let startY     = VlogLayout.hitokotoBlockTop(
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
                        .position(x: canvas.width / 2, y: y)
                }
            }
        }
    }
}
