import Foundation
import Testing
@testable import MyVlogApp

/// ファイル名からの撮影日時の読み取り。Android: VideoMetadataReaderTest
///
/// 実ファイルを開く経路（AVAsset/PHAsset）はテストできないので、純粋に文字列だけで
/// 決まるこの部分を守る。撮影時刻メタデータが失われた動画（SNS経由・PCで変換・画面録画）で
/// 実際に効いてくる手がかり。
@Suite("ファイル名からの撮影日時")
struct VideoMetadataReaderTests {

    /// 端末のローカル時刻として解釈されるので、比較側も同じカレンダーで組み立てる
    private func localDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        return calendar.date(from: components)!
    }

    @Test("Pixelのカメラ名 PXL_yyyyMMdd_HHmmssSSS")
    func pixelCamera() {
        #expect(VideoMetadataReader.shotAtFromFileName("PXL_20260901_101500123.mp4")
            == localDate(2026, 9, 1, 10, 15, 0))
    }

    @Test("画面録画の名前 yyyyMMdd-HHmmss")
    func screenRecording() {
        #expect(VideoMetadataReader.shotAtFromFileName("Screen_Recording_20260901-101500.mp4")
            == localDate(2026, 9, 1, 10, 15, 0))
    }

    @Test("区切りのある形 yyyy-MM-dd HH-mm-ss")
    func separated() {
        #expect(VideoMetadataReader.shotAtFromFileName("2026-09-01 10-15-00.mov")
            == localDate(2026, 9, 1, 10, 15, 0))
        #expect(VideoMetadataReader.shotAtFromFileName("2026.09.01_10.15.00.mov")
            == localDate(2026, 9, 1, 10, 15, 0))
    }

    @Test("午前・午後の表記を解釈する")
    func meridiem() {
        #expect(VideoMetadataReader.shotAtFromFileName("2026-09-01 at 10.15.00 AM.mov")
            == localDate(2026, 9, 1, 10, 15, 0))
        #expect(VideoMetadataReader.shotAtFromFileName("2026-09-01 at 10.15.00 PM.mov")
            == localDate(2026, 9, 1, 22, 15, 0))
        // 午前0時台は 12 AM と書かれる
        #expect(VideoMetadataReader.shotAtFromFileName("2026-09-01 at 12.05.00 AM.mov")
            == localDate(2026, 9, 1, 0, 5, 0))
    }

    @Test("日付だけで時刻が無い名前は対象外")
    func dateOnlyIsIgnored() {
        #expect(VideoMetadataReader.shotAtFromFileName("IMG-20260901-WA0001.mp4") == nil)
    }

    @Test("存在しない日時は読まない（繰り上げで別の日にしない）")
    func invalidDateIsRejected() {
        #expect(VideoMetadataReader.shotAtFromFileName("20261301_101500.mp4") == nil)   // 13月
        #expect(VideoMetadataReader.shotAtFromFileName("20260901_251500.mp4") == nil)   // 25時
        #expect(VideoMetadataReader.shotAtFromFileName("20260931_101500.mp4") == nil)   // 9/31
    }

    @Test("ありえない年の並びは拾わない")
    func implausibleYear() {
        #expect(VideoMetadataReader.shotAtFromFileName("18990901_101500.mp4") == nil)
    }

    @Test("日時が含まれない名前は nil")
    func noDateInName() {
        #expect(VideoMetadataReader.shotAtFromFileName("movie.mp4") == nil)
        #expect(VideoMetadataReader.shotAtFromFileName("") == nil)
    }
}
