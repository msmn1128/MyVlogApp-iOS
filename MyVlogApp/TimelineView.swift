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
                    .environmentObject(store)
                    .environmentObject(playerManager)

                if !store.clips.isEmpty {
                    clipRow

                    WaveformView()
                        .environmentObject(store)
                        .environmentObject(playerManager)
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

    @State private var thumbnail: UIImage? = nil
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Thumbnail / background
            if let img = thumbnail {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 90)
                    .clipped()
            } else {
                AppColors.card(colorScheme)
                    .frame(width: 80, height: 90)
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
            .frame(width: 80, height: 90, alignment: .bottomLeading)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            // Split badge
            if clip.texts.count > 1 {
                Text("1-\(clip.texts.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(AppColors.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(4)
                    .frame(width: 80, height: 90, alignment: .topTrailing)
            }
        }
        .frame(width: 80, height: 90)
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
        .onAppear { loadThumbnail() }
    }

    private func loadThumbnail() {
        guard thumbnail == nil else { return }
        if let id = clip.assetIdentifier {
            let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
            guard let asset = fetchResult.firstObject else { return }
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .opportunistic
            opts.isNetworkAccessAllowed = true
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 160, height: 180),
                contentMode: .aspectFill,
                options: opts
            ) { img, _ in
                Task { @MainActor in thumbnail = img }
            }
        } else if let url = clip.resolvedFileURL {
            Task {
                let av  = AVURLAsset(url: url)
                let gen = AVAssetImageGenerator(asset: av)
                gen.appliesPreferredTrackTransform = true
                let time = CMTime(seconds: 0.1, preferredTimescale: 600)
                let img  = try? await gen.image(at: time).image
                await MainActor.run { thumbnail = img.map(UIImage.init) }
            }
        }
    }

    private func durationLabel(_ ms: Int64) -> String {
        Formatters.durationLabel(ms: ms)
    }
}
