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
    var isValid: Bool { durationMs > 0 && endMs > startMs }
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
