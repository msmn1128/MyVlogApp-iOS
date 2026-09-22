import SwiftUI
import AVFoundation

@main
struct MyVlogAppApp: App {
    // 保存先はAppEnvironmentが決める（通常はUserDefaults.standard、UIテスト時だけ使い捨ての領域）。
    // @Observableなクラスは@StateObjectではなく@Stateで保持する
    @State private var store         = VlogStore(defaults: AppEnvironment.defaults)
    @State private var playerManager = VideoPlayerManager()
    @State private var exportManager = ExportManager()

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
                .environment(store)
                .environment(playerManager)
                .environment(exportManager)
                .onAppear { playerManager.store = store }
                // UIテストの起動引数が渡されたときだけ、テスト用のクリップを入れる。
                // 通常起動では何もしない（UITestSupport.swift 参照）
                .task {
                    #if DEBUG
                    await UITestSupport.seedClipsIfRequested(into: store)
                    #endif
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                playerManager.pause()
            }
        }
    }
}
