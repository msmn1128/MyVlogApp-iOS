import SwiftUI
import AVFoundation

@main
struct MyVlogAppApp: App {
    @StateObject private var store         = VlogStore()
    @StateObject private var playerManager = VideoPlayerManager()
    @StateObject private var exportManager = ExportManager()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        configureAudioSession()
    }

    private func configureAudioSession() {
        do {
            // .playbackを排他（mixWithOthersなし）で有効化していると、システムソフトキーボードが
            // キー操作音用に必要とするオーディオセッションと競合し、実機でフォーカス（アクセサリ
            // ツールバー）はつくのにキーボード本体だけが一切描画されない、という現象を引き起こす
            // ことがある（テキストフィールドの実装や画面レイアウトとは無関係に発生する）。
            // .mixWithOthersを付けて他のオーディオセッションと共存できるようにする。
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioSession] Failed to configure: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(playerManager)
                .environmentObject(exportManager)
                .onAppear { playerManager.store = store }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                playerManager.pause()
            }
        }
    }
}
