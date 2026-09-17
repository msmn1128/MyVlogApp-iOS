import Foundation

/// クリップ/ひとこと欄のデータそのもの（可変状態を持たない値型）はどのactorからも
/// awaitなしで安全に参照できる必要があるため、プロジェクト全体の既定
/// （SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）から明示的に外してある
/// （AssetLoader/ThumbnailLoader/ExportWorkerなど@MainActor以外のactorから参照するため。
/// 詳しい経緯はFontLoader.swiftのコメントを参照）
nonisolated struct TextSegment: Codable, Equatable, Hashable {
    var startMs: Int64 = 0
    var text: String = "ひとこと"
}

nonisolated struct VlogClip: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var assetIdentifier: String?    // PHAsset.localIdentifier
    var fileURL: URL?               // Legacy file:// URL for file picker videos
    var relativeFilePath: String?   // Relative filename inside Documents directory
    var timeText: String            // "HH:mm"
    var dateText: String            // "yyyy/MM/dd"
    var durationMs: Int64
    var width: Int
    var height: Int
    var texts: [TextSegment]
    var startMs: Int64
    var endMs: Int64
    var isMuted: Bool = false   // このクリップの音声を書き出しで無音にするか（Android: VlogModels.kt isMuted）
    var shotAtMillis: Int64 = 0 // 撮影/作成日時（並び替えの基準）。0は未取得・旧データ

    /// タイムライン全体のミュート状態と合わせて、書き出し時に無音にすべきか判定する
    func isSilentInExport(timelineMuted: Bool) -> Bool { isMuted || timelineMuted }

    /// 並び替えの基準。shotAtMillisが無い旧データはdateText/timeTextから逆算する
    /// （Android: VlogModels.kt sortKeyMs / parseShotAtText）
    var sortKeyMs: Int64 {
        if shotAtMillis > 0 { return shotAtMillis }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        if let date = formatter.date(from: "\(dateText) \(timeText)") {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return .max
    }

    private enum CodingKeys: String, CodingKey {
        case id, assetIdentifier, fileURL, relativeFilePath, timeText, dateText
        case durationMs, width, height, texts, startMs, endMs, isMuted, shotAtMillis
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        assetIdentifier  = try c.decodeIfPresent(String.self, forKey: .assetIdentifier)
        fileURL          = try c.decodeIfPresent(URL.self, forKey: .fileURL)
        relativeFilePath = try c.decodeIfPresent(String.self, forKey: .relativeFilePath)
        timeText         = try c.decode(String.self, forKey: .timeText)
        dateText         = try c.decode(String.self, forKey: .dateText)
        durationMs       = try c.decode(Int64.self, forKey: .durationMs)
        width            = try c.decode(Int.self, forKey: .width)
        height           = try c.decode(Int.self, forKey: .height)
        texts            = try c.decode([TextSegment].self, forKey: .texts)
        startMs          = try c.decode(Int64.self, forKey: .startMs)
        endMs            = try c.decode(Int64.self, forKey: .endMs)
        isMuted          = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        shotAtMillis     = try c.decodeIfPresent(Int64.self, forKey: .shotAtMillis) ?? 0
    }

    init(
        id: UUID = UUID(),
        assetIdentifier: String? = nil,
        fileURL: URL? = nil,
        relativeFilePath: String? = nil,
        timeText: String,
        dateText: String,
        durationMs: Int64,
        width: Int,
        height: Int,
        texts: [TextSegment],
        startMs: Int64,
        endMs: Int64,
        isMuted: Bool = false,
        shotAtMillis: Int64 = 0
    ) {
        self.id = id
        self.assetIdentifier = assetIdentifier
        self.fileURL = fileURL
        self.relativeFilePath = relativeFilePath
        self.timeText = timeText
        self.dateText = dateText
        self.durationMs = durationMs
        self.width = width
        self.height = height
        self.texts = texts
        self.startMs = startMs
        self.endMs = endMs
        self.isMuted = isMuted
        self.shotAtMillis = shotAtMillis
    }

    var resolvedFileURL: URL? {
        if let rel = relativeFilePath {
            let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            return docURL?.appendingPathComponent(rel)
        }
        if let url = fileURL {
            let docURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            if let candidate = docURL?.appendingPathComponent(url.lastPathComponent),
               FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            return url
        }
        return nil
    }

    static let minTrimMs: Int64 = 300
    static let splitMinDistanceMs: Int64 = 400

    /// インポート直後の初期状態（全区間選択・ひとこと1つ）でクリップを作る。
    /// フォトライブラリ由来（assetIdentifier）とファイル由来（fileURL/relativeFilePath）で
    /// 共通していた組み立て末尾を1箇所にまとめた（ContentView+Import.swift）
    static func imported(
        assetIdentifier: String? = nil,
        fileURL: URL? = nil,
        relativeFilePath: String? = nil,
        timeText: String,
        dateText: String,
        durationMs: Int64,
        width: Int,
        height: Int,
        shotAt: Date
    ) -> VlogClip {
        VlogClip(
            id:               UUID(),
            assetIdentifier:  assetIdentifier,
            fileURL:          fileURL,
            relativeFilePath: relativeFilePath,
            timeText:         timeText,
            dateText:         dateText,
            durationMs:       durationMs,
            width:            max(1, width),
            height:           max(1, height),
            texts:            [TextSegment()],
            startMs:          0,
            endMs:            durationMs,
            shotAtMillis:     Int64(shotAt.timeIntervalSince1970 * 1000)
        )
    }

    var trimmedDurationMs: Int64 { max(0, endMs - startMs) }
    var splitPoints: [Int64] { texts.dropFirst().map { $0.startMs } }

    /// トリム範囲内へ丸めたシーク先。波形のドラッグ/タップ処理で繰り返し使う
    func clampToTrim(_ ms: Int64) -> Int64 { max(startMs, min(endMs, ms)) }

    func textIndexAt(positionMs: Int64) -> Int {
        var result = 0
        for (i, seg) in texts.enumerated() {
            if seg.startMs <= positionMs { result = i }
        }
        return result
    }

    func textAt(positionMs: Int64) -> String {
        guard !texts.isEmpty else { return "" }
        return texts[textIndexAt(positionMs: positionMs)].text
    }

    /// tolerance(最大1500ms)が区切りの最小間隔(400ms)より大きいため、1つの位置の
    /// 許容範囲に複数の区切りが入りうる。「最初に見つかった区切り」ではなく
    /// 「最も近い区切り」を返す（Android: VlogModels.kt splitPointNearと同じ、minByOrNull方式）
    func splitPointNear(positionMs: Int64) -> Int64? {
        let tolerance = max(200, min(1500, durationMs / 40))
        return splitPoints
            .filter { abs($0 - positionMs) <= tolerance }
            .min { abs($0 - positionMs) < abs($1 - positionMs) }
    }

    /// Returns (relativeStartMs, relativeEndMs, text) relative to startMs (0 = clip start after trim)
    func visibleTextSpans() -> [(spanStart: Int64, spanEnd: Int64, text: String)] {
        guard !texts.isEmpty else { return [] }
        var result: [(Int64, Int64, String)] = []
        for (i, seg) in texts.enumerated() {
            let segEnd = (i + 1 < texts.count) ? texts[i + 1].startMs : durationMs
            guard segEnd > startMs && seg.startMs < endMs else { continue }
            let clampedStart = max(seg.startMs, startMs) - startMs
            let clampedEnd = min(segEnd, endMs) - startMs
            if clampedEnd > clampedStart {
                result.append((clampedStart, clampedEnd, seg.text))
            }
        }
        return result
    }
}

struct SavedProject: Codable, Identifiable {
    let id: Int64
    var name: String
    let savedAt: Int64
    let clipCount: Int
    let totalMs: Int64
    var clips: [VlogClip]
}
