import SwiftUI
import Photos

/// 「タイムライン」カード全体。Android版TimelinePaneと同じく、見出し・操作バー・
/// クリップ一覧（または空メッセージ）を1枚のカードにまとめる。
struct TimelineView: View {
    @EnvironmentObject var store:         VlogStore
    @EnvironmentObject var playerManager: VideoPlayerManager
    @Environment(\.colorScheme) var colorScheme

    @State private var showDeleteAllAlert: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("タイムライン")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))

            OperationBar(showDeleteAllAlert: $showDeleteAllAlert)
                .environmentObject(store)
                .environmentObject(playerManager)

            if store.clips.isEmpty {
                HStack {
                    Spacer()
                    Text("動画を追加するとここに並びます")
                        .font(.system(size: 12))
                        .foregroundStyle(AppColors.onSurfaceVariant(colorScheme))
                    Spacer()
                }
                .padding(.vertical, 24)
            } else {
                clipRow

                WaveformView()
                    .environmentObject(store)
                    .environmentObject(playerManager)
                    .frame(height: 95)
                    .padding(.top, 8)
            }
        }
        .padding(12)
        .background(AppColors.card(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .alert("すべて削除", isPresented: $showDeleteAllAlert) {
            Button("削除", role: .destructive) { store.deleteAllClips() }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("すべてのクリップを削除します。Undoで戻せます。")
        }
    }

    private var clipRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(store.clips.enumerated()), id: \.element.id) { idx, clip in
                        ClipTile(
                            clip:       clip,
                            isSelected: idx == store.selectedIndex,
                            onToggleMute: { store.toggleMute(at: idx) }
                        )
                        .id(idx)
                        .onTapGesture {
                            store.selectedIndex = idx
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
    let onToggleMute: () -> Void

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

                Text(durationLabel(clip.trimmedDurationMs))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(radius: 1)
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

            // Mute toggle
            Button(action: onToggleMute) {
                Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(clip.isMuted ? Color.red.opacity(0.85) : Color.black.opacity(0.45))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(4)
            .frame(width: 80, height: 90, alignment: .topLeading)

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
        let s = ms / 1000
        let m = s / 60
        return String(format: "%d:%02d", m, s % 60)
    }
}
