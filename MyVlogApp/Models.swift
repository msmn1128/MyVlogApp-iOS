import Foundation

struct TextSegment: Codable, Equatable, Hashable {
    var startMs: Int64 = 0
    var text: String = "ひとこと"
}

struct VlogClip: Identifiable, Codable, Equatable {
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

    var trimmedDurationMs: Int64 { max(0, endMs - startMs) }
    var splitPoints: [Int64] { texts.dropFirst().map { $0.startMs } }

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

    func splitPointNear(positionMs: Int64) -> Int64? {
        let tolerance = max(200, min(1500, durationMs / 40))
        return splitPoints.first { abs($0 - positionMs) <= tolerance }
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
