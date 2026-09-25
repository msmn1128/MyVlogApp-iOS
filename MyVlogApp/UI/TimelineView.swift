import SwiftUI
import Photos

/// 「タイムライン」カード全体。Android版TimelinePaneと同じく、見出し・操作バー・
/// クリップ一覧（または空メッセージ）を1枚のカードにまとめる。
struct TimelineView: View {
    @Environment(VlogStore.self) private var store
    @Environment(VideoPlayerManager.self) private var playerManager
    @Environment(ExportManager.self) private var exportManager
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("タイムライン")
                    .vlogFont(14, weight: .semibold)
                    .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))

                OperationBar()

                if !store.clips.isEmpty {
                    clipRow

                    if let clip = store.selectedClip {
                        trimSection(clip)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.card(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// 選択中クリップのトリム表示（Android: TrimSection）。
    ///
    /// 波形の上に「撮影時刻：使っている範囲（長さ）」を出す。つまみの位置だけでは、何秒から何秒を
    /// 使っているのか読み取れないため。最短のトリム（VlogClip.minTrimMs）より短い動画はつまみの
    /// 可動域が無いので波形を出さず、理由を出す（長さが取れなかった動画も同じ）
    @ViewBuilder
    private func trimSection(_ clip: VlogClip) -> some View {
        if clip.durationMs >= VlogClip.minTrimMs {
            Text(
                "\(clip.timeText)：\(Formatters.durationLabel(ms: clip.startMs)) 〜 "
                    + "\(Formatters.durationLabel(ms: clip.endMs))"
                    + "（\(Formatters.durationLabel(ms: Formatters.roundedTrimMs(startMs: clip.startMs, endMs: clip.endMs)))）"
            )
            .vlogFont(12)
            .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
            .padding(.top, 6)

            WaveformView()
                .frame(height: 95)
                .padding(.top, 4)
        } else {
            Text(clip.durationMs <= 0 ? "この動画は長さを取得できませんでした" : "この動画は短すぎてトリミングできません")
                .vlogFont(12)
                .foregroundStyle(AppColors.error(colorScheme))
                .padding(.top, 6)
        }
    }

    /// タイルの位置（タイル一覧の見えている範囲を原点にした座標）。選択が変わったときに、
    /// そのタイルが見えているかを判断するためだけに覚えておく。
    /// スクロールのたびに全タイルぶん書き換わるので、画面の再描画を起こさない入れ物に入れる
    @State private var tileFrames = TileFrames()
    @State private var clipRowWidth: CGFloat = 0

    private var clipRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(store.clips.enumerated()), id: \.element.id) { idx, clip in
                        ClipTile(
                            clip: clip,
                            isSelected: idx == store.selectedIndex,
                            isMissing: store.missingClipIds.contains(clip.id)
                        )
                            // 目印はクリップのidにする（ForEachと同じ）。以前は並びの番号（idx）を付けていたため、
                            // 手前のクリップを削除・並べ替えると後ろのタイルの目印が変わり、SwiftUIが別のタイルとして
                            // 作り直していた。サムネイルがいったん消えて出し直され、新しい位置へ滑らかに動くはずの
                            // アニメーション（操作バーのwithAnimation）も、消えて現れるだけになっていた
                            .id(clip.id)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.clipRowSpace)) } action: {
                                tileFrames.frames[idx] = $0
                            }
                            // 選んだら止めて頭を出す（同じタイルを選び直したときも。Android: select）
                            .onTapGesture { playerManager.select(index: idx) }
                            // Android版ClipTile: タップ=選択、長押し=ミュート切替（combinedClickable）
                            // 書き出し中はミュートを切り替えさせない（操作バーなど、ほかの編集と同じ）。書き出すのは
                            // 押した時点の内容なので、切り替えても出来上がる動画には入らず、画面と食い違って見える
                            // （Android: ClipTile の onLongClick = null）
                            .onLongPressGesture(minimumDuration: 0.5) {
                                guard !exportManager.isExporting else { return }
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                store.toggleMute(at: idx)
                            }
                            // VoiceOver用のアクション（Android: combinedClickableのonClickLabel/onLongClickLabel相当）
                            .accessibilityElement(children: .combine)
                            // 枠線の太さでしか示していない選択状態を、読み上げにも乗せる。
                            // 何本目かも言わないと、どのクリップを触っているのか分からない
                            .accessibilityLabel(
                                store.missingClipIds.contains(clip.id)
                                    ? "\(idx + 1)本目のクリップ。動画が見つかりません（移動・削除されたか、アクセス権限が取り消されています）"
                                    : "\(idx + 1)本目のクリップ"
                            )
                            // ミュート中かも伝える。タイルの中のアイコンは、読み上げを1つにまとめた（combine）ラベルに
                            // 上書きされて読まれず、VoiceOverではミュート中だと分からなかった（Android: アイコンの「ミュート中」）
                            .accessibilityValue(clip.isMuted ? "ミュート中" : "")
                            .accessibilityAddTraits(
                                idx == store.selectedIndex ? [.isButton, .isSelected] : [.isButton]
                            )
                            .accessibilityAction { playerManager.select(index: idx) }
                            .modifier(MuteAccessibilityAction(
                                isMuted: clip.isMuted, enabled: !exportManager.isExporting
                            ) {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                store.toggleMute(at: idx)
                            })
                    }
                }
                .padding(.vertical, 6)
            }
            .coordinateSpace(.named(Self.clipRowSpace))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { clipRowWidth = $0 }
            // 選択中のタイルが常に見えるようにする。連続再生で次へ進んだときや「ひとつ後ろへ移動」で、
            // タイルが画面外のままになると、いまどれを編集しているのか分からなくなるため。
            //
            // すでに全部見えているタイルは動かさない。以前は毎回そのタイルを中央まで送っていたので、
            // 見えているタイルを押しただけで並びが横に動き、続けて押そうとした指の下のタイルが
            // 入れ替わっていた（長押しのミュートが別のクリップに効く）。はみ出しているときは、
            // はみ出した側の端へ寄せるだけにする（Android f12806b）
            .onChange(of: store.selectedIndex) { _, idx in
                guard let idx, store.clips.indices.contains(idx) else { return }
                let id = store.clips[idx].id
                // 位置は並びの番号で覚えてある（タイルの幅はそろっているので、番号ごとの場所は並べ替えても変わらない）。
                // 並べ替えた直後は、動かしたタイルの位置の知らせがまだ届いていないため、クリップごとに覚えると
                // 動かす前の場所で判断してしまう
                guard let frame = tileFrames.frames[idx], clipRowWidth > 0 else {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                    return
                }
                if frame.minX < 0 {
                    withAnimation { proxy.scrollTo(id, anchor: .leading) }
                } else if frame.maxX > clipRowWidth {
                    withAnimation { proxy.scrollTo(id, anchor: .trailing) }
                }
            }
        }
    }

    private static let clipRowSpace = "clipRow"
}

/// 読み上げの「ミュート」の操作を、切り替えられるとき（書き出し中でないとき）だけ出す
private struct MuteAccessibilityAction: ViewModifier {
    let isMuted: Bool
    let enabled: Bool
    let action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content.accessibilityAction(named: isMuted ? "ミュートを解除" : "ミュート", action)
        } else {
            content
        }
    }
}

/// タイルの位置の入れ物。@Observableにしない（書き換えても画面を描き直さない）のが要点
private final class TileFrames {
    var frames: [Int: CGRect] = [:]
}

private struct ClipTile: View {
    let clip:       VlogClip
    let isSelected: Bool
    /// 動画を開けなくなった（移動・削除された、アクセスが取り消された）か。枠を赤くして警告の目印を出す。
    /// 再生と書き出しでも知らせるが、タイルを見ただけでどれを外せばよいか分かるようにする（Android: ClipTile）
    let isMissing:  Bool

    /// タイルの大きさ。中に撮影時刻・ひとこと・尺の3行を抱えるので、文字サイズ設定に
    /// 合わせて一緒に伸ばす（固定のままだと大きい文字設定で3行が収まらず切れる）
    @ScaledMetric(relativeTo: .body) private var tileWidth:  CGFloat = 80
    @ScaledMetric(relativeTo: .body) private var tileHeight: CGFloat = 90
    private var tileSize: CGSize { CGSize(width: tileWidth, height: tileHeight) }

    @State private var thumbnail: UIImage? = nil
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Thumbnail / background
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: tileSize.width, height: tileSize.height)
                    .clipped()
            } else {
                AppColors.card(colorScheme)
                    .frame(width: tileSize.width, height: tileSize.height)
            }

            // Info overlay
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.timeText)
                    .vlogFont(10, weight: .semibold)
                    .foregroundStyle(.white)
                    .shadow(radius: 1)

                Spacer()

                // トリム開始位置に今かかっている区間の文言を表示する（Android: TimelineSection.kt
                // clip.textAt(clip.startMs)と同じ）。以前は常にtexts[0]（先頭区間）を表示しており、
                // 複数区間に分割済みのクリップでトリム開始を先頭の区切りより後ろへずらすと、
                // 実際にはもう表示範囲外になった区間の文言が表示され続けるズレがあった。
                Text(hitokotoTileText)
                    .vlogFont(9)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(radius: 1)

                HStack(spacing: 4) {
                    // 波形の上の範囲の表示（「0:03 〜 0:15（0:12）」）と同じ値にそろえる
                    Text(durationLabel(Formatters.roundedTrimMs(startMs: clip.startMs, endMs: clip.endMs)))
                        .vlogFont(9, design: .monospaced)
                        .foregroundStyle(.white.opacity(0.8))
                        .shadow(radius: 1)

                    // ミュート中のクリップは長押ししないと気付けないので、常時アイコンで示す
                    // （Android: ClipTileのVolumeOffアイコンと同じ、非タップの表示専用）
                    if clip.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .vlogFont(9)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .vlogFont(9)
                            .foregroundStyle(AppColors.error(colorScheme))
                    }
                }
            }
            .padding(5)
            .frame(width: tileSize.width, height: tileSize.height, alignment: .bottomLeading)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Split badge
            // AnimatedVisibilityのように出し入れせず、常にレイアウトへ含めて
            // 透明度だけを変える（Android: TimelineSection.ktのsegmentBadgeAlphaと同じ狙い）。
            // 条件で丸ごと出し入れすると、分割の瞬間にバッジがパッと現れて見える。
            Text("1-\(clip.texts.count)")
                .vlogFont(9, weight: .bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(AppColors.primary)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(4)
                .frame(width: tileSize.width, height: tileSize.height, alignment: .topTrailing)
                .opacity(clip.texts.count > 1 ? 1 : 0)
                .animation(.default, value: clip.texts.count > 1)
        }
        .frame(width: tileSize.width, height: tileSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isMissing ? AppColors.error(colorScheme)
                        : isSelected ? AppColors.primary : AppColors.primary.opacity(0.25),
                    lineWidth: isSelected || isMissing ? 2.5 : 1
                )
        )
        // 選択状態の切り替わりで枠線が一瞬で変わらず、じわっと変化するようにする
        // （Android版ClipTileのanimateColorAsStateと同じ狙い）
        .animation(.default, value: isSelected)
        .animation(.default, value: isMissing)
        .transition(.opacity)
        .task(id: clip.id) { await loadThumbnail() }
    }

    /// PHAsset/ファイルの分岐やPHImageManagerへの直接リクエストはThumbnailLoaderへ
    /// 集約済み（AssetLoaderと同じキャッシュ付きの設計）。ここは結果を@Stateへ
    /// 受け取るだけの薄い呼び出しになる
    private func loadThumbnail() async {
        let requestSize = CGSize(width: tileSize.width * 2, height: tileSize.height * 2)
        let img = await ThumbnailLoader.shared.thumbnail(for: clip, size: requestSize, scale: displayScale)
        thumbnail = img
    }

    private func durationLabel(_ ms: Int64) -> String {
        Formatters.durationLabel(ms: ms)
    }

    /// 未入力（空文字か空白だけ）なら、入力欄の案内文字と同じ「ひとこと」を目印に出す
    /// （Android: TimelineSection.ktの`.ifBlank { DEFAULT_HITOKOTO }`と同じ）
    private var hitokotoTileText: String {
        let text = clip.textAt(positionMs: clip.startMs)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? TextSegment.defaultText : text
    }
}
