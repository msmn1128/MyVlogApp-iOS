import SwiftUI
import Photos

/// 「タイムライン」カード全体。Android版TimelinePaneと同じく、見出し・操作バー・
/// クリップ一覧（または空メッセージ）を1枚のカードにまとめる。
struct TimelineView: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("タイムライン")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))

                OperationBar()

                if !store.clips.isEmpty {
                    clipRow

                    WaveformView()
                        .frame(height: 95)
                        .padding(.top, 8)
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.card(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var clipRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(store.clips.enumerated()), id: \.element.id) { idx, clip in
                        ClipTile(clip: clip, isSelected: idx == store.selectedIndex)
                            .id(idx)
                            .onTapGesture {
                                store.selectedIndex = idx
                            }
                            // Android版ClipTile: タップ=選択、長押し=ミュート切替（combinedClickable）
                            .onLongPressGesture(minimumDuration: 0.5) {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                store.toggleMute(at: idx)
                            }
                            // VoiceOver用のアクション（Android: combinedClickableのonClickLabel/onLongClickLabel相当）
                            .accessibilityElement(children: .combine)
                            .accessibilityAction { store.selectedIndex = idx }
                            .accessibilityAction(named: clip.isMuted ? "ミュートを解除" : "ミュート") {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                store.toggleMute(at: idx)
                            }
                    }
                }
                .padding(.vertical, 6)
            }
            .onChange(of: store.selectedIndex) { _, idx in
                if let idx { withAnimation { proxy.scrollTo(idx, anchor: .center) } }
            }
        }
    }
}

private struct ClipTile: View {
    let clip:       VlogClip
    let isSelected: Bool

    private let tileSize = CGSize(width: 80, height: 90)

    @State private var thumbnail: UIImage? = nil
    @Environment(\.colorScheme) var colorScheme

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
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 1)

                Spacer()

                Text(clip.texts.first?.text ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(radius: 1)

                HStack(spacing: 4) {
                    Text(durationLabel(clip.trimmedDurationMs))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .shadow(radius: 1)

                    // ミュート中のクリップは長押ししないと気付けないので、常時アイコンで示す
                    // （Android: ClipTileのVolumeOffアイコンと同じ、非タップの表示専用）
                    if clip.isMuted {
                        Image(systemName: "speaker.slash.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.8))
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
                .font(.system(size: 9, weight: .bold))
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
                    isSelected ? AppColors.primary : AppColors.primary.opacity(0.25),
                    lineWidth: isSelected ? 2.5 : 1
                )
        )
        // 選択状態の切り替わりで枠線が一瞬で変わらず、じわっと変化するようにする
        // （Android版ClipTileのanimateColorAsStateと同じ狙い）
        .animation(.default, value: isSelected)
        .transition(.opacity)
        .task(id: clip.id) { await loadThumbnail() }
    }

    /// PHAsset/ファイルの分岐やPHImageManagerへの直接リクエストはThumbnailLoaderへ
    /// 集約済み（AssetLoaderと同じキャッシュ付きの設計）。ここは結果を@Stateへ
    /// 受け取るだけの薄い呼び出しになる
    private func loadThumbnail() async {
        let requestSize = CGSize(width: tileSize.width * 2, height: tileSize.height * 2)
        let img = await ThumbnailLoader.shared.thumbnail(for: clip, size: requestSize)
        thumbnail = img
    }

    private func durationLabel(_ ms: Int64) -> String {
        Formatters.durationLabel(ms: ms)
    }
}
