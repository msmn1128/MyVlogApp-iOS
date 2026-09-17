import Foundation

/// 日付・時刻・尺の文字列フォーマットをまとめたヘルパー（Android: Formatters.kt相当）。
/// 各Viewに同じ書式のDateFormatterがバラバラに書かれてズレるのを防ぐため、ここに集約する。
enum Formatters {
    /// DateFormatterの既定ロケール（端末設定）はカレンダー種別・数字体系がユーザー環境依存になる。
    /// timeText/dateTextは書き出し映像にそのまま焼き込まれる文字なので、非グレゴリオ暦や
    /// 非アラビア数字圏の端末でも常に同じ字形になるよう固定する（Android: FormattersのLocale.USと
    /// 同じ狙い。Models.swiftのsortKeyMsフォールバックと同じen_US_POSIXを使う）。
    private static let fixedLocale = Locale(identifier: "en_US_POSIX")

    /// クリップのタイムライン表示用「HH:mm」「yyyy/MM/dd」（ContentView: formatDate）
    static func clipTimeAndDate(_ date: Date) -> (time: String, date: String) {
        let tf = DateFormatter(); tf.locale = fixedLocale; tf.dateFormat = "HH:mm"
        let df = DateFormatter(); df.locale = fixedLocale; df.dateFormat = "yyyy/MM/dd"
        return (tf.string(from: date), df.string(from: date))
    }

    /// 保存プロジェクト一覧の「保存日時」表示用「M/d HH:mm"（SavedProjectsView: savedAtLabel）
    static func savedAtLabel(msSinceEpoch: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(msSinceEpoch) / 1000)
        let f = DateFormatter(); f.locale = fixedLocale; f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }

    /// 一時保存の既定名「M/d」。同名があれば「M/d (1)」のように連番を付ける
    /// （Android: defaultSaveName、SavedProjectsView: nextDefaultName）
    static func defaultSaveName(baseDate: Date = Date(), existingNames: Set<String>) -> String {
        let formatter = DateFormatter()
        formatter.locale = fixedLocale
        formatter.dateFormat = "M/d"
        let base = formatter.string(from: baseDate)
        var candidate = base
        var index = 1
        while existingNames.contains(candidate) {
            candidate = "\(base) (\(index))"
            index += 1
        }
        return candidate
    }

    /// ミリ秒を「m:ss」表記に（TimelineView: durationLabel、SavedProjectsView: durationLabel）
    static func durationLabel(ms: Int64) -> String {
        let s = ms / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
