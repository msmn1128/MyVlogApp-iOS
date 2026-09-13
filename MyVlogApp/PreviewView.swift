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
            .contentShape(Rectangle())
            .onTapGesture { playerManager.togglePlayPause() }
        }
    }

    // MARK: - Overlay text

    private func overlayContent(clip: VlogClip, canvas: CGSize, scale: CGFloat) -> some View {
        let pos          = playerManager.currentTimeMs
        let hitokoroText = clip.textAt(positionMs: pos)
        let timeText     = clip.timeText

        return ZStack {
            // ─── ひとこと: 上下左右中央 ───
            hitokoroOverlay(text: hitokoroText, canvas: canvas, scale: scale)

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

    private func hitokoroOverlay(text: String, canvas: CGSize, scale: CGFloat) -> some View {
        let lines      = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let fontSize   = VlogLayout.hitokoroFontSize * scale
        let lineGap    = VlogLayout.hitokoroLineGap * scale
        let lineHeight = fontSize + lineGap
        let totalH     = lineHeight * CGFloat(lines.count) - lineGap
        // 上下左右中央: Y は canvas 中心から均等に配置
        let startY     = canvas.height * 0.5 - totalH / 2

        return ZStack {
            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                let y = startY + CGFloat(idx) * lineHeight + fontSize / 2
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
