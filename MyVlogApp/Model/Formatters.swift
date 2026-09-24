import Foundation

/// 日付・時刻・尺の文字列フォーマットと、画面に出す通知文の組み立てをまとめたヘルパー
/// （Android: Formatters.kt相当）。各Viewに同じ書式のDateFormatterや同じ文言が
/// バラバラに書かれてズレるのを防ぐため、ここに集約する。
///
/// どれも可変状態を持たない純粋関数なので、@MainActorがプロジェクト全体の既定に
/// なっていてもどこからでも呼べるようnonisolatedにしてある（単体テストからも直接呼ぶ）。
nonisolated enum Formatters {
    /// DateFormatterの既定ロケール（端末設定）はカレンダー種別・数字体系がユーザー環境依存になる。
    /// timeText/dateTextは書き出し映像にそのまま焼き込まれる文字なので、非グレゴリオ暦や
    /// 非アラビア数字圏の端末でも常に同じ字形になるよう固定する（Android: FormattersのLocale.USと
    /// 同じ狙い。Models.swiftのsortKeyMsフォールバックと同じen_US_POSIXを使う）。
    private static let fixedLocale = Locale(identifier: "en_US_POSIX")

    // MARK: - 日時・尺の整形

    /// クリップのタイムライン表示用「HH:mm」「yyyy/MM/dd」（ContentView: formatDate）
    static func clipTimeAndDate(_ date: Date) -> (time: String, date: String) {
        let tf = DateFormatter(); tf.locale = fixedLocale; tf.dateFormat = "HH:mm"
        let df = DateFormatter(); df.locale = fixedLocale; df.dateFormat = "yyyy/MM/dd"
        return (tf.string(from: date), df.string(from: date))
    }

    /// 保存プロジェクト一覧の「保存日時」表示用「M/d HH:mm」（SavedProjectsView: savedAtLabel）
    static func savedAtLabel(msSinceEpoch: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(msSinceEpoch) / 1000)
        let f = DateFormatter(); f.locale = fixedLocale; f.dateFormat = "M/d HH:mm"
        return f.string(from: date)
    }

    /// ミリ秒を「m:ss」表記に（Android: formatSeconds）。
    ///
    /// 秒は四捨五入する。切り捨てだと、トリミングの範囲の表示が「0:03 〜 0:15（0:11）」
    /// （実際は3.2〜15.1秒、11.9秒）のように、引き算と合わなく見えていた。長さの側は
    /// `roundedTrimMs`で、丸めた両端の差にそろえる。数字の字形はPOSIXロケールで固定する
    static func durationLabel(ms: Int64) -> String {
        let s = roundToSecondMs(max(0, ms)) / 1000
        return String(format: "%d:%02d", locale: fixedLocale, s / 60, s % 60)
    }

    /// トリミング後の長さの、表示用の値。両端をそれぞれ秒へ丸めてから差を取る（Android: roundedTrimMs）。
    ///
    /// 長さそのもの（end−start）を丸めると、両端の表示の引き算と1秒ずれることがある
    /// （3.5〜15.4秒は「0:04 〜 0:15」なのに、長さ11.9秒を丸めると「0:12」）。
    /// 表示はだいたいの目安なので、見た目の引き算が必ず合う方を採る。書き出しの長さには使わないこと。
    static func roundedTrimMs(startMs: Int64, endMs: Int64) -> Int64 {
        max(0, roundToSecondMs(endMs) - roundToSecondMs(startMs))
    }

    /// 秒の単位へ四捨五入したミリ秒
    private static func roundToSecondMs(_ ms: Int64) -> Int64 { (ms + 500) / 1000 * 1000 }

    /// 書き出す動画のファイル名「Vlog_yyyy-MM-dd.mp4」（Android: GalleryOutput.buildDisplayName）。
    ///
    /// タイトルカードの文言は使わない。自由入力は改行やパス区切り文字を含みうるため、
    /// 書き出した日付から作るほうが常に安全な文字だけで済む。
    /// 日付の区切りにハイフンを使うのは、ファイル名にスラッシュを含められないため。
    ///
    /// Androidは同名があれば「Vlog_2026-09-21 (1).mp4」と連番を付けるが、iOSで同じ重複チェックを
    /// するには写真ライブラリの読み取り権限（保存に必要な`.addOnly`より広い）が要り、書き出しの
    /// たびに権限ダイアログが増える。その副作用のほうが実害が大きいのでチェックはせず、
    /// 同名時の扱いは写真アプリ側の解決に任せる。
    static func exportFileName(exportedAt: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = fixedLocale
        formatter.dateFormat = "yyyy-MM-dd"
        return "Vlog_\(formatter.string(from: exportedAt)).mp4"
    }

    // MARK: - 保存名

    /// `base`と同じ名前が`existingNames`にすでにあれば、「base (1)」「base (2)」のように
    /// 空いている最初の連番を付けて返す。無ければ`base`のまま（Android: uniqueSaveName）。
    ///
    /// 一時保存の名前（既定値・自分で打った名前のどちらも）で使う。以前は既定値を作るときにしか
    /// 重複を見ておらず、自分で打った名前は同名のまま並んでしまっていた。
    static func uniqueSaveName(base: String, existingNames: Set<String>) -> String {
        var candidate = base
        var index = 1
        while existingNames.contains(candidate) {
            candidate = "\(base) (\(index))"
            index += 1
        }
        return candidate
    }

    /// 一時保存の既定名「M/d」。同名があれば「M/d (1)」のように連番を付ける
    /// （Android: defaultSaveName、SavedProjectsView: nextDefaultName）
    static func defaultSaveName(baseDate: Date = Date(), existingNames: Set<String>) -> String {
        let formatter = DateFormatter()
        formatter.locale = fixedLocale
        formatter.dateFormat = "M/d"
        return uniqueSaveName(base: formatter.string(from: baseDate), existingNames: existingNames)
    }

    // MARK: - 通知文（Android: Formatters.kt の各メッセージ関数）

    /// 動画を追加したあとに出す、スキップの通知文。どれも0件ならnil（通知しない）。
    ///
    /// 件数は引き算で辻褄を合わせるのではなく理由ごとに数える。以前は
    /// 「選んだ件数 − 追加できた件数」で出しており、同じ動画を2回選んだだけで
    /// 「長さを取得できませんでした」と出るなど理由を取り違えていた（Android: addSkipMessage）。
    ///
    /// - Parameters:
    ///   - alreadyAdded: すでにタイムラインにあったため追加しなかった件数
    ///   - unreadable: 長さなどを読み取れなかったため追加しなかった件数
    ///   - overLimit: クリップ数の上限を超えるため追加しなかった件数
    static func addSkipMessage(
        alreadyAdded: Int,
        unreadable: Int,
        overLimit: Int = 0,
        limit: Int = VlogLayout.maxClips
    ) -> String? {
        var lines: [String] = []
        if alreadyAdded > 0 { lines.append("\(alreadyAdded) 件は追加済みのためスキップしました") }
        if unreadable > 0 {
            lines.append("\(unreadable) 件は読み込めなかったので追加しませんでした（もう一度選び直してください）")
        }
        if overLimit > 0 { lines.append("\(overLimit) 件は上限（\(limit)本）を超えるため追加しませんでした") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 一時保存を読み出して、いまのタイムラインを置き換えてよいか。
    ///
    /// 保存内の動画が1本も読めないのに置き換えると、作業中のタイムラインが空になってしまう
    /// （動画が削除・移動された、アクセス権限が取り消された場合など）。その場合は置き換えない。
    /// 保存自体が空（読めなかった動画も無い）のときは、そのまま読み出せる（Android: canReplaceWithProject）。
    static func canReplaceWithProject(loaded: Int, dropped: Int) -> Bool {
        loaded > 0 || dropped == 0
    }

    /// 一時保存を読み出したあとの通知文。もとに戻せることも添える（Android: projectLoadedMessage）
    static func projectLoadedMessage(dropped: Int) -> String {
        dropped > 0
            ? "読み出しました（\(dropped) 件の動画は見つかりませんでした）。もとに戻すで読み出す前へ戻ります"
            : "読み出しました（もとに戻すで読み出す前へ戻ります）"
    }

    /// 読める動画が1本も無くて読み出さなかったときの通知文（Android: projectUnreadableMessage）
    static func projectUnreadableMessage(dropped: Int) -> String {
        "この保存の動画は \(dropped) 件とも見つからないため、読み出しませんでした"
            + "（移動・削除されたか、アクセス権限が取り消されています）"
    }

    /// 前回の続き（自動保存）を復元したときに、開けなかった動画があれば出す通知文
    static func restoreDroppedMessage(dropped: Int) -> String {
        "\(dropped) 件の動画は復元できませんでした（移動・削除されたか、アクセス権限が取り消されています）"
    }
}
