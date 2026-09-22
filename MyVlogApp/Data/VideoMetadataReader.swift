import AVFoundation
import Foundation
import Photos

// =====================================================================================
// 動画から撮影日時・長さ・表示サイズを読む（Android: data/VideoMetadataReader.kt）。
//
// 以前はこの処理が ContentView+Import.swift の中にだけあり、取り込み時にしか使えなかった。
// 「撮影時刻が確かでないクリップを次回起動時に取り直す」（VlogStore+Persistence の
// refreshUnreliableShotTimes）にも同じ読み取りが要るため、ここへ切り出して共有する。
// =====================================================================================

/// 動画から読み取ったメタデータ（Android: VideoMeta）
nonisolated struct VideoMeta: Sendable {
    let timeText: String
    let dateText: String
    let shotAtMillis: Int64
    /// 撮影時刻を、動画自体が持つ確かな手がかりから取れたか（VlogClip.shotAtReliable）
    let shotAtReliable: Bool
    let durationMs: Int64
    let width: Int
    let height: Int
}

nonisolated enum VideoMetadataReader {

    /// すでにタイムラインにあるクリップのメタデータを読み直す（撮影時刻の取り直し用）。
    /// 参照先が開けない場合はnil（呼び出し側はそのクリップに触らない）。
    static func read(for clip: VlogClip, fallbackDate: Date) async -> VideoMeta? {
        if let identifier = clip.assetIdentifier {
            return readPhotoLibraryAsset(identifier: identifier, fallbackDate: fallbackDate)
        }
        if let url = clip.resolvedFileURL {
            return await readFile(at: url, originalFileName: url.lastPathComponent, fallbackDate: fallbackDate)
        }
        return nil
    }

    // MARK: - フォトライブラリ（PHAsset）

    /// PHAssetは撮影日時（creationDate）を構造化して持っているので、動画を開かずに読める。
    /// creationDateが無いのは、他アプリが書き込んだ素材など限られた場合。
    static func readPhotoLibraryAsset(identifier: String, fallbackDate: Date) -> VideoMeta? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = result.firstObject, asset.duration > 0, asset.duration.isFinite else { return nil }
        let durationMs = Int64(asset.duration * 1000)
        guard durationMs > 0 else { return nil }

        // creationDateが無ければ取り込み時刻で代用する。まとめて取り込むと全部同じ値になるので
        // 「確かな撮影時刻」とは言えない。reliable=falseにして次回起動時に一度だけ取り直させる
        let reliable = asset.creationDate != nil
        let shotAt = asset.creationDate ?? fallbackDate

        return meta(
            shotAt: shotAt, reliable: reliable, durationMs: durationMs,
            width: asset.pixelWidth, height: asset.pixelHeight
        )
    }

    // MARK: - ファイル（AVURLAsset）

    /// - Parameter originalFileName: 撮影時刻をファイル名から読むときに使う名前。
    ///   取り込み時はDocumentsへ`UUID_元の名前`でコピーするため、元の名前を別に渡してもらう。
    static func readFile(at url: URL, originalFileName: String, fallbackDate: Date) async -> VideoMeta? {
        let asset = AVURLAsset(url: url)
        async let durationTask = asset.load(.duration)
        async let tracksTask   = asset.load(.tracks)
        async let metadataTask = asset.load(.metadata)

        guard let duration = try? await durationTask, duration.seconds > 0, duration.seconds.isFinite else {
            return nil
        }
        let durationMs = Int64(duration.seconds * 1000)
        guard durationMs > 0 else { return nil }

        let (width, height) = await displaySize(tracks: try? await tracksTask)
        let (shotAt, reliable) = await resolveShotAt(
            metadata: (try? await metadataTask) ?? [],
            fileURL: url,
            originalFileName: originalFileName,
            fallbackDate: fallbackDate
        )

        return meta(shotAt: shotAt, reliable: reliable, durationMs: durationMs, width: width, height: height)
    }

    /// 撮影時刻の手がかりを優先順に探す（Android: guessShotAt と同じ考え方）。
    ///  1. 埋め込みの作成日時（creation_time）
    ///  2. ファイル名に含まれる日時（"PXL_20260901_101500" など。カメラアプリ・画面録画の命名規則）
    ///  3. ファイルの作成／更新日時。コピーしても保たれることが多い
    ///  4. どれも取れなければ取り込み時刻（確かではない＝reliable false）
    private static func resolveShotAt(
        metadata: [AVMetadataItem], fileURL: URL, originalFileName: String, fallbackDate: Date
    ) async -> (Date, Bool) {
        if let date = await creationDate(from: metadata) { return (date, true) }
        if let date = shotAtFromFileName(originalFileName) { return (date, true) }
        if let date = fileDate(of: fileURL) { return (date, true) }
        return (fallbackDate, false)
    }

    private static func displaySize(tracks: [AVAssetTrack]?) async -> (Int, Int) {
        guard let track = tracks?.first(where: { $0.mediaType == .video }) else { return (1920, 1080) }
        async let sizeTask = track.load(.naturalSize)
        async let transformTask = track.load(.preferredTransform)
        guard let naturalSize = try? await sizeTask, let transform = try? await transformTask else {
            return (1920, 1080)
        }
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return (Int(abs(rect.width).rounded()), Int(abs(rect.height).rounded()))
    }

    private static func fileDate(of url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let candidate = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date)
        // MP4の日時は1904年起点で、未設定のまま書かれたファイルはエポック以前として読める。
        // それを撮影日時に採ると日付も並び順も1904年になるため「無い」扱いにする
        return candidate.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
    }

    // MARK: - 埋め込みメタデータ

    private static func creationDate(from metadata: [AVMetadataItem]) async -> Date? {
        for identifier in [AVMetadataIdentifier.commonIdentifierCreationDate,
                           .quickTimeMetadataCreationDate] {
            let items = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: identifier)
            if let item = items.first, let date = await date(from: item) { return date }
        }
        return nil
    }

    /// dateValue/stringValueを1回のロード呼び出しでまとめて取得する
    /// （別々にawaitすると同じitemへの往復が2回になる）
    private static func date(from item: AVMetadataItem) async -> Date? {
        guard let (dateValue, stringValue) = try? await item.load(.dateValue, .stringValue) else { return nil }
        if let dateValue, dateValue.timeIntervalSince1970 > 0 { return dateValue }
        if let stringValue, let parsed = parseDateString(stringValue), parsed.timeIntervalSince1970 > 0 {
            return parsed
        }
        return nil
    }

    private static func parseDateString(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: string) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: string) { return date }

        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy:MM:dd HH:mm:ss",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy-MM-dd"
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    // MARK: - ファイル名からの撮影日時

    /// "20260901-101500" / "20260901_101500" / "PXL_20260901_101500123" のような、日付と時刻が続く形
    private static let compactPattern =
        #"(?<!\d)(\d{4})(\d{2})(\d{2})[-_ T]?(\d{2})(\d{2})(\d{2})(?:\d{3})?(?!\d)"#

    /// "2026-09-01 10-15-00" / "2026.09.01_10.15.00" / "2026-09-01 at 10.15.00 AM" のような、区切りのある形
    private static let separatedPattern =
        #"(?<!\d)(\d{4})[-_.](\d{2})[-_.](\d{2})[-_ T.]+(?:at\s+)?(\d{1,2})[-_.:](\d{2})[-_.:](\d{2})(?!\d)(?:\s*([AaPp][Mm]))?"#

    /// ファイル名に含まれる撮影日時を読む（端末のローカル時刻として解釈する）。
    /// 見つからない、または存在しない日時（月が13など）のときはnil。
    /// 日付だけで時刻が無い名前（"IMG-20260901-WA0001" など）は時刻が分からないので対象外。
    /// テストから直接呼ぶためinternal（Android: parseShotTimeFromFileName）。
    static func shotAtFromFileName(_ name: String) -> Date? {
        for pattern in [compactPattern, separatedPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(name.startIndex..., in: name)
            for match in regex.matches(in: name, range: range) {
                if let date = dateFromMatch(match, in: name) { return date }
            }
        }
        return nil
    }

    private static func dateFromMatch(_ match: NSTextCheckingResult, in name: String) -> Date? {
        func group(_ index: Int) -> String? {
            guard index < match.numberOfRanges,
                  let range = Range(match.range(at: index), in: name) else { return nil }
            return String(name[range])
        }
        guard let year = group(1).flatMap(Int.init), (1990...2100).contains(year),
              let month = group(2).flatMap(Int.init),
              let day = group(3).flatMap(Int.init),
              var hour = group(4).flatMap(Int.init),
              let minute = group(5).flatMap(Int.init),
              let second = group(6).flatMap(Int.init) else { return nil }

        switch group(7)?.lowercased() {
        case "pm": if hour < 12 { hour += 12 }
        case "am": if hour == 12 { hour = 0 }
        default:   break
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        guard let date = calendar.date(from: components) else { return nil }

        // 存在しない日時（13月・25時など）をCalendarは繰り上げて別の日にしてしまうので、
        // 組み立てた結果が入力と一致するかを確かめる（KotlinのCalendar.isLenient=false相当）。
        // DateComponents同士の==は比較できない（dateComponents(_:from:)の戻り値には
        // calendar/timeZoneも入る）ため、フィールドごとに突き合わせる
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == hour, actual.minute == minute, actual.second == second
        else { return nil }
        return date
    }

    // MARK: - 組み立て

    private static func meta(
        shotAt: Date, reliable: Bool, durationMs: Int64, width: Int, height: Int
    ) -> VideoMeta {
        let (time, date) = Formatters.clipTimeAndDate(shotAt)
        return VideoMeta(
            timeText: time,
            dateText: date,
            shotAtMillis: Int64(shotAt.timeIntervalSince1970 * 1000),
            shotAtReliable: reliable,
            durationMs: durationMs,
            width: max(1, width),
            height: max(1, height)
        )
    }
}
