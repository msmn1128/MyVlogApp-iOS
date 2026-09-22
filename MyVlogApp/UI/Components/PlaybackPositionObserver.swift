import SwiftUI

/// 再生位置の変化だけを拾う、大きさを持たない葉ビュー。
///
/// 親のbodyに直接 `.onChange(of: playerManager.currentTimeMs)` と書くと、
/// **親のbodyが再生位置を読んだことになる**。Observationは「bodyで読んだプロパティ」を
/// 依存として記録するため、再生位置は約33msごとに変わる以上、親のbody全体が
/// 毎秒30回作り直されてしまう（UITextViewの更新など重い処理を含んでいると効く）。
///
/// 監視だけをこの葉に閉じ込めれば、無効化されるのはこの`Color.clear`だけで済む。
/// Android版が再生位置を`State<Long>`のまま渡し、値を読む場所を葉のComposableに
/// 限定しているのと同じ狙い。
struct PlaybackPositionObserver: View {
    @Environment(VideoPlayerManager.self) private var playerManager

    /// 再生位置（ミリ秒）が変わるたびに呼ばれる
    let onChange: (Int64) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: playerManager.currentTimeMs) { _, newValue in onChange(newValue) }
    }
}
