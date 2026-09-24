import Foundation

/// クリップ/ひとこと欄のデータそのもの（可変状態を持たない値型）はどのactorからも
/// awaitなしで安全に参照できる必要があるため、プロジェクト全体の既定
/// （SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor）から明示的に外してある
/// （AssetLoader/ThumbnailLoader/ExportWorkerなど@MainActor以外のactorから参照するため。
/// 詳しい経緯はFontLoader.swiftのコメントを参照）
nonisolated struct TextSegment: Codable, Equatable, Hashable {
    var startMs: Int64 = 0
    /// 既定は空文字。以前は「ひとこと」そのものを入れていたため、動画を追加して
    /// 触らずに書き出すと、文字通り「ひとこと」がプレビューと動画に焼き込まれていた
    /// （Android: TextSegment）。
    var text: String = ""

    /// 未入力の入力欄に出すグレーの案内文字と、タイムラインのタイルで未入力の目印に
    /// 出す文字。値としては使わない（Android: DEFAULT_HITOKOTO）
    static let defaultText = "ひとこと"

    /// これ以上は詰められない区間の長さ。短すぎる区間は読む前に消えてしまう
    /// （Android: MIN_TEXT_SEGMENT_MS）
    static let minSegmentMs: Int64 = 400

    /// 保存データから読んだ区間を「必ず1件以上・先頭のstartMsは0・昇順」へ揃える
    /// （Android: VlogModels.kt readTextSegments）。
    ///
    /// この3つが崩れると`textIndexAt`/`visibleTextSpans`が拾えない区間を作り、
    /// 書き出しから文字が消える。並びが崩れているだけなら文言は全部活かしたいので、
    /// 全区間を白紙に差し替えるのではなく「並べ替え」と「先頭の位置だけ0へ」に留める
    /// （1件目のstartMsが壊れているだけで残り全部の文言まで消さないため）。
    ///
    /// 負の位置は0へ丸めてから並べる。下で直すのは先頭の1件だけなので、負の位置が2件以上あると
    /// 2件目以降が0より前に残り、昇順が崩れていた（[-5, -3, 1000] → [0, -3, 1000]。Android cd569d5）
    static func normalized(_ segments: [TextSegment]) -> [TextSegment] {
        guard !segments.isEmpty else { return [TextSegment()] }
        let sorted = segments
            .map { TextSegment(startMs: max(0, $0.startMs), text: $0.text) }
            .sorted { $0.startMs < $1.startMs }
        guard let first = sorted.first, first.startMs != 0 else { return sorted }
        var head = first
        head.startMs = 0
        return [head] + sorted.dropFirst()
    }
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

    /// ファイル取り込みのクリップが「同じ動画か」を見分けるための指紋（`FileContentKey`）。
    ///
    /// フォトライブラリ由来は`assetIdentifier`で同一と分かるので付けない（nilのまま）。
    /// ファイル取り込みは毎回別名でコピーするため、これが無いと同じ動画を2回選んでも
    /// 重複を検知できなかった。この項目を持たない古い保存データではnilになり、
    /// そのクリップは従来どおり重複判定の対象外になる（壊れはしない）。
    var contentKey: String?

    /// 撮影時刻を、動画自体が持つ確かな手がかり（PHAssetのcreationDate・動画メタデータの
    /// creation_time・ファイルの作成日時）から取れたか。falseは手がかりが足りず取り込み時刻で
    /// 代用した値で、次回の復元時に取り直す（VlogStore+Persistence.refreshUnreliableShotTimes）。
    /// 保存データに無い旧データはfalse扱い（Android: VlogClip.shotAtReliable）。
    var shotAtReliable: Bool = true

    /// `shotAtReliable`がfalseのクリップについて、動画から取り直すのを一度試したか。
    ///
    /// 手がかりが本当に何も無い動画は何度取り直しても確かな値にならない。これが無いと、
    /// そういう動画が1本でもタイムラインに残っている限り、起動のたびに全部を開き直す処理が
    /// 走り続ける（Android: VlogClip.shotAtRefreshed）。
    var shotAtRefreshed: Bool = false

    /// タイムライン全体のミュート状態と合わせて、書き出し時に無音にすべきか判定する
    func isSilentInExport(timelineMuted: Bool) -> Bool { isMuted || timelineMuted }

    /// 書き出しに出せるクリップか。尺0や範囲の逆転したクリップは書き出しを止めてしまうので、
    /// 追加時と書き出し前の両方で弾く（Android: VlogClip.isValid）
    var isValid: Bool { durationMs > 0 && endMs > startMs }

    /// 並び替えの基準。shotAtMillisが無い旧データはdateText/timeTextから逆算する
    /// （Android: VlogModels.kt sortKeyMs / parseShotAtText）
    var sortKeyMs: Int64 {
        if shotAtMillis > 0 { return shotAtMillis }
        if let date = Self.legacyShotAtFormatter.date(from: "\(dateText) \(timeText)") {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return .max
    }

    /// 撮影時刻を持たない古い保存データの並べ替えに使う。並べ替えの比較のたびに作っていたので1つだけ作る。
    /// DateFormatterはスレッドをまたいで使ってよい（Sendable）ので、共有にしてある
    private static let legacyShotAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    private enum CodingKeys: String, CodingKey {
        case id, assetIdentifier, fileURL, relativeFilePath, timeText, dateText
        case durationMs, width, height, texts, startMs, endMs, isMuted, shotAtMillis
        case shotAtReliable, shotAtRefreshed, contentKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id               = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        assetIdentifier  = try c.decodeIfPresent(String.self, forKey: .assetIdentifier)
        fileURL          = try c.decodeIfPresent(URL.self, forKey: .fileURL)
        relativeFilePath = try c.decodeIfPresent(String.self, forKey: .relativeFilePath)
        timeText         = try c.decode(String.self, forKey: .timeText)
        dateText         = try c.decode(String.self, forKey: .dateText)
        width            = try c.decode(Int.self, forKey: .width)
        height           = try c.decode(Int.self, forKey: .height)
        isMuted          = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        shotAtMillis     = try c.decodeIfPresent(Int64.self, forKey: .shotAtMillis) ?? 0
        // 確かさを持たせる前の保存データにはキー自体が無い。追加時の手がかりが足りなかった値が
        // 混ざっている可能性があるのでfalseにして、次回の復元時に一度だけ取り直させる
        shotAtReliable   = try c.decodeIfPresent(Bool.self, forKey: .shotAtReliable) ?? false
        shotAtRefreshed  = try c.decodeIfPresent(Bool.self, forKey: .shotAtRefreshed) ?? false
        // 指紋を持たせる前の保存データにはキー自体が無い。nilのままにしておけば、
        // そのクリップは重複判定の対象外になるだけで従来どおり動く
        contentKey       = try c.decodeIfPresent(String.self, forKey: .contentKey)

        // ひとことは「必ず1件以上・先頭は0・昇順」へ揃えてから入れる。この不変条件が崩れていると
        // textIndexAt/visibleTextSpansが拾えない区間を作り、書き出しから文字が消える
        // （Android: VlogClip.fromJson → readTextSegments）
        texts = TextSegment.normalized(try c.decode([TextSegment].self, forKey: .texts))

        // トリム位置は「0 <= start <= end <= 尺」へ正規化してから入れる。保存データが壊れていて
        // end < start のままだと、範囲を前提にしている計算（トリム幅・波形の描画範囲）が
        // 一斉におかしくなる。読めた値は活かしつつ、前後が入れ替わっている分だけを直す
        // （ひとことや並び順は巻き添えにしない。Android: VlogClip.fromJson）
        let decodedDuration = try c.decode(Int64.self, forKey: .durationMs)
        let duration        = max(0, decodedDuration)
        let decodedStart    = try c.decode(Int64.self, forKey: .startMs)
        let decodedEnd      = try c.decode(Int64.self, forKey: .endMs)
        durationMs = duration
        startMs    = min(max(decodedStart, 0), duration)
        endMs      = min(max(decodedEnd, startMs), duration)
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
        shotAtMillis: Int64 = 0,
        shotAtReliable: Bool = true,
        shotAtRefreshed: Bool = false,
        contentKey: String? = nil
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
        self.shotAtReliable = shotAtReliable
        self.shotAtRefreshed = shotAtRefreshed
        self.contentKey = contentKey
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
    static let splitMinDistanceMs: Int64 = TextSegment.minSegmentMs

    /// 「同じ動画か」を見分ける鍵（追加済みの判定に使う。planAddition / VlogStore.addClips）。
    /// フォトライブラリ由来は識別子、ファイル取り込みは中身の指紋。どちらも無い古い保存データはnil
    /// （重複判定の対象外）。種類ごとに頭を付けて、識別子と指紋が偶然一致しても混ざらないようにする
    var identityKey: String? {
        if let assetIdentifier { return Self.assetIdentityKey(assetIdentifier) }
        if let contentKey { return Self.contentIdentityKey(contentKey) }
        return nil
    }
    static func assetIdentityKey(_ identifier: String) -> String { "asset:" + identifier }
    static func contentIdentityKey(_ key: String) -> String { "content:" + key }

    /// 波形/サムネイル/AVAssetのキャッシュを引くときのキー。
    ///
    /// clip.idではなく「素材そのもの」を指す値にしてあるのは、同じ動画を2回追加したときに
    /// デコードをやり直さずに済ませるため（Android: 波形キャッシュをURIで持つのと同じ理由）。
    /// 解放の判定（VlogStore.releaseUnusedMediaCaches）も、この値がタイムラインに
    /// 1つも残っていないことを見て行う。
    var mediaCacheKey: String {
        assetIdentifier ?? relativeFilePath ?? fileURL?.absoluteString ?? id.uuidString
    }

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
        shotAt: Date,
        shotAtReliable: Bool,
        contentKey: String? = nil
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
            shotAtMillis:     Int64(shotAt.timeIntervalSince1970 * 1000),
            shotAtReliable:   shotAtReliable,
            contentKey:       contentKey
        )
    }

    var trimmedDurationMs: Int64 { max(0, endMs - startMs) }
    var splitPoints: [Int64] { texts.dropFirst().map { $0.startMs } }

    /// トリム範囲だけを取り出した値。
    ///
    /// `ContentView`が「選択中クリップのトリムが変わったか」をonChangeで見るために使う。
    /// clip全体（`texts`を含む）を比較の対象にすると、ひとことを1文字打つたびに
    /// トリムの監視まで発火してしまうため、この2つだけに絞れる形にしてある。
    var trimBounds: TrimBounds { TrimBounds(startMs: startMs, endMs: endMs) }

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

/// クリップのトリム範囲（開始・終了）だけを表す値（`VlogClip.trimBounds`）。
///
/// AVPlayer側のトリム終端の監視（`VideoPlayerManager.updateTrimBounds`）は、波形の
/// ドラッグ以外の経路（トリムプリセット・もとに戻す/やり直す）でも更新する必要がある。
/// その追従をonChangeで書くには「トリムだけを取り出したEquatableな値」が要る。
nonisolated struct TrimBounds: Equatable {
    var startMs: Int64
    var endMs:   Int64
}

// =====================================================================================
// VoiceOverの「調整」操作（上下スワイプ）でトリムを動かすときの計算。
//
// 波形はCanvas描画で、つまみはドラッグでしか動かせなかった＝支援技術からは
// トリムを一切変更できなかった。調整操作を足すにあたって、ドラッグと同じ制約
// （動画の範囲内・最短トリムを割らない）を効かせる必要がある。
// 画面（WaveformView）に書くとテストできないので、ここへ純粋関数として置く
// （clampTimelineShiftと同じ考え方）。
// =====================================================================================

/// 「調整」1回で動かす量。
///
/// 細かすぎると目的の位置まで何十回もスワイプすることになり、粗すぎると
/// 合わせられない。クリップの長さの50分の1を基準に、0.1〜1秒の範囲へ収める。
nonisolated func accessibilityAdjustStepMs(durationMs: Int64) -> Int64 {
    max(100, min(1_000, durationMs / 50))
}

/// トリム開始を`deltaMs`だけ動かした先。0より手前と、終了から最短トリム未満へは行かない
nonisolated func adjustedTrimStartMs(clip: VlogClip, deltaMs: Int64) -> Int64 {
    max(0, min(clip.endMs - VlogClip.minTrimMs, clip.startMs + deltaMs))
}

/// トリム終了を`deltaMs`だけ動かした先。尺より後ろと、開始から最短トリム未満へは行かない
nonisolated func adjustedTrimEndMs(clip: VlogClip, deltaMs: Int64) -> Int64 {
    max(clip.startMs + VlogClip.minTrimMs, min(clip.durationMs, clip.endMs + deltaMs))
}

/// 区間ごと移動（VlogStore.moveTrim）で、実際にずらせる量。
///
/// トリム範囲とひとことの区切りは「相対位置を保ったままひとかたまりで動く」のが狙いなので、
/// 区切りだけを1つずつ範囲へ丸めてはいけない。以前は各区切りを `min(max(s + delta, 1), durationMs)`
/// で丸めていたため、トリムより手前に残っている区切り（頭を落としたあとの分）を含むクリップを
/// 大きく左へ動かすと、それらが先頭付近へ潰れて相対位置が失われ、「もとに戻す」以外で
/// 復元できなくなっていた。代わりに、全部が同じ量で動けるところまで`requested`自体を詰める
/// （Android: VlogModels.kt clampTimelineShift）。
///
/// 先頭の区間（`startMs == 0`）は動画そのものの頭なので動かさない。よって他の区切りの下限は
/// `TextSegment.minSegmentMs`、上限は動画の尺。すでにその範囲を外れている保存データを
/// 動かせなくしてしまわないよう、許容範囲には必ず0（＝動かさない）を含める。
///
/// - Parameter requested: トリム開始位置の移動量（動画の範囲へクランプ済み）
/// - Returns: 実際にずらす量
nonisolated func clampTimelineShift(texts: [TextSegment], requested: Int64, durationMs: Int64) -> Int64 {
    // 移動の対象になるのは、先頭（絶対位置0）以外の区切りだけ
    let moving = texts.filter { $0.startMs != 0 }
    guard let lowest = moving.map(\.startMs).min(),
          let highest = moving.map(\.startMs).max() else { return requested }

    let lo = min(TextSegment.minSegmentMs - lowest, 0)
    let hi = max(durationMs - highest, 0)
    return min(max(requested, lo), hi)
}

struct SavedProject: Codable, Identifiable {
    let id: Int64
    var name: String
    let savedAt: Int64
    let clipCount: Int
    let totalMs: Int64
    var clips: [VlogClip]
    /// 読み込むときに壊れていて飛ばしたクリップの本数。保存はしない。
    /// 読み出したときに「N件の動画は見つかりませんでした」へ数えるため（Android: readableClipsのdropped）
    var droppedClipCount: Int = 0

    private enum CodingKeys: String, CodingKey {
        case id, name, savedAt, clipCount, totalMs, clips
    }
}

extension SavedProject {
    /// クリップは1件ずつ読む（理由はLossyList）。extensionに置くのは、型の本体に書くと
    /// 自動で作られる全項目のinitが消えるため
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let clips = try c.decode(LossyList<VlogClip>.self, forKey: .clips)
        self.init(
            id:        try c.decode(Int64.self, forKey: .id),
            name:      try c.decode(String.self, forKey: .name),
            savedAt:   try c.decode(Int64.self, forKey: .savedAt),
            clipCount: try c.decode(Int.self, forKey: .clipCount),
            totalMs:   try c.decode(Int64.self, forKey: .totalMs),
            clips:     clips.elements,
            droppedClipCount: clips.droppedCount
        )
    }
}
