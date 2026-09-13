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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
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
