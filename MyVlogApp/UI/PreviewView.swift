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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if store.selectedClip == nil {
            emptyGuide
        } else {
            canvas
        }
    }

    /// クリップが無いときの案内（Android: PreviewPane の selectedClip == null）。
    /// 黒いキャンバスだけでは、何をすればよいのか分からなかった
    private var emptyGuide: some View {
        ZStack {
            AppColors.card(colorScheme)
            Text("「動画を追加」から動画を選んでください")
                .vlogFont(14)
                .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                .multilineTextAlignment(.center)
                .padding(24)
        }
    }

    private var canvas: some View {
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
                    // 見せるだけで、タップは下のプレビューへ素通りさせる。覆いがタップを受け止めていたため、
                    // 読み込み中にプレビューを押しても再生の操作が届かず、何も起きなかった
                    // （届けば、読み込み終わったところで再生が始まる。AVPlayerが再生するつもりを保つため）
                    ZStack {
                        Color.black.opacity(0.45)
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(1.5)
                    }
                    .allowsHitTesting(false)
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
        // 押すと何が起きるかを、ボタンとして伝える（Android: onClickLabel「再生／一時停止」・Role.Button）。
        // 付けていなかった頃は、VoiceOverではプレビューを押せることが分からなかった
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { playerManager.togglePlayPause() }
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

    /// ひとこと。書き出しと同じ描画関数（CaptionRenderer）で描くので、位置・大きさ・絵文字の出方が
    /// 書き出した動画と一致する。以前はSwiftUIのTextで描いていて、絵文字や他のフォントで補った字が
    /// 入ると行の高さが変わり、行ごと上下へずれていた（書き出し側もずれ方が違った）。
    /// 折り返さず、キャンバスより長い行は書き出しと同じく左右へ均等にはみ出す（外は親で切る）
    private func hitokotoOverlay(text: String) -> some View {
        HitokotoCanvas(text: text, scale: scale)
            .frame(width: canvas.width, height: canvas.height)
            .allowsHitTesting(false)
    }
}

/// ひとことを描くだけの葉。文字と倍率が変わらなければ描き直さない
/// （再生位置が変わるたびに親が作り直されても、区間が同じなら描き直しは起きない）
private struct HitokotoCanvas: View, Equatable {
    let text: String
    let scale: CGFloat

    var body: some View {
        Canvas { context, size in
            context.withCGContext { cg in
                CaptionRenderer.drawHitokoto(text, canvas: size, scale: scale, in: cg)
            }
        }
    }
}
