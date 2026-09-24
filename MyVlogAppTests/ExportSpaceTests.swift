import AVFoundation
import Foundation
import Testing
@testable import MyVlogApp

/// 書き出しに要る空き容量の見積もりと、容量不足・開けない動画の文言。Android: ExportSpaceTest
@Suite("書き出しの事前確認")
struct ExportSpaceTests {

    @Test("出来上がりは長さ×ビットレートで見積もり、要る空きはその2倍＋余裕")
    func estimatesFromDuration() {
        // 60秒 × (12Mbps + 128kbps) / 8 = 90.96MB
        #expect(ExportSpace.estimatedOutputBytes(durationMs: 60_000) == 90_960_000)
        #expect(ExportSpace.requiredFreeBytes(durationMs: 60_000) == 90_960_000 * 2 + ExportSpace.marginBytes)
    }

    @Test("書き出しの長さはタイトルカードとトリム後の長さの合計")
    func exportDurationIncludesTitle() {
        let clips = [TestClip.make(durationMs: 10_000, startMs: 1_000, endMs: 4_000), TestClip.make(durationMs: 5_000)]
        #expect(ExportSpace.exportDurationMs(clips: clips, includeTitle: true) == 2_000 + 3_000 + 5_000)
        #expect(ExportSpace.exportDurationMs(clips: clips, includeTitle: false) == 8_000)
    }

    @Test("容量不足の文言は、要る量と使える空きを読める単位で出す")
    func notEnoughSpaceMessage() {
        let message = ExportSpace.notEnoughSpaceMessage(required: 1_503_238_553, available: 256 * 1024 * 1024)
        #expect(message.contains("約1.4GB必要"))
        #expect(message.contains("使える空きは256MB"))
    }

    @Test("容量不足のエラーは、包まれていても見分ける")
    func recognizesNoSpaceErrors() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(ExportSpace.isNoSpaceError(wrapped))
        #expect(ExportSpace.isNoSpaceError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        #expect(!ExportSpace.isNoSpaceError(NSError(domain: AVFoundationErrorDomain, code: -11800)))
    }

    @Test("開けない動画は何本目のどの動画かを伝える")
    func missingClipsMessage() {
        let clips = [TestClip.make(timeText: "09:00"), TestClip.make(timeText: "10:30"), TestClip.make(timeText: "11:45")]
        let message = Formatters.missingClipsMessage(indices: [0, 2], clips: clips)
        #expect(message.hasPrefix("1本目（09:00）、3本目（11:45）の動画が見つかりません。"))
    }

    @Test("書き出しに失敗した文言は日本語で始め、元の文言は括弧に添える")
    func failureMessageIsJapanese() {
        let avError = NSError(domain: AVFoundationErrorDomain, code: -11800,
                              userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed"])
        #expect(ExportManager.failureMessage(for: avError) == "書き出しに失敗しました（The operation could not be completed）")
        // アプリ自身のエラーはその日本語のまま
        #expect(ExportManager.failureMessage(for: ExportError.noVideoTrack) == "動画トラックが見つかりません")
        // 容量不足はどうすればよいかまで
        #expect(ExportManager.failureMessage(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
                == ExportSpace.ranOutOfSpaceMessage)
    }

    @Test("起動時の後始末は、起動より前の作業ファイルだけを消し、始まったばかりの書き出しのファイルは残す")
    func cleanupKeepsFilesOfTheCurrentExport() throws {
        // 回帰テスト: 後始末は後回しの優先度で走るので、走る頃には書き出しが始まっていることがあり、
        // その作業ファイルまで消して書き出しを失敗させていた
        let tmp = FileManager.default.temporaryDirectory
        let old = tmp.appendingPathComponent("clipvideo_cleanuptest_old_\(UUID().uuidString).mov")
        let current = tmp.appendingPathComponent("clipvideo_cleanuptest_new_\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: current) }
        // 前回の起動で残ったファイル → 起動 → いまの書き出しが作ったファイル、の順
        try Data([0]).write(to: old)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)
        let launchedAt = Date()
        try Data([0]).write(to: current)

        ExportWorker.cleanupOrphanedWorkFiles(createdBefore: launchedAt)

        #expect(!FileManager.default.fileExists(atPath: old.path), "前回の残骸が消えていない")
        #expect(FileManager.default.fileExists(atPath: current.path), "いまの書き出しの作業ファイルを消した")
    }
}
