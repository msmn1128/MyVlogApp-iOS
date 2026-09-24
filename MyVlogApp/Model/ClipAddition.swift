import Foundation

/// 動画を追加するとき、選ばれた動画をどう振り分けるか（`planAddition`の結果。Android: AdditionPlan）
nonisolated struct AdditionPlan<Element> {
    /// 読み込んで追加を試みるもの（選んだ順）
    var toLoad: [Element]
    /// すでにタイムラインにあるので外したもの
    var alreadyAdded: Int
    /// 上限を超えるので、読まずに断ったもの
    var overLimit: Int
}

/// 選ばれた動画を、追加済み・上限超え・読み込むものに振り分ける（Android: ClipAddition.kt planAddition）。
///
/// - 同じ動画かは`keyOf`の鍵の一致で判断する。フォトライブラリは識別子、ファイルは中身の指紋
///   （FileContentKey）。鍵の取れない動画（識別子の無いフォトピッカーの項目など）は重複を判定できないので、
///   常に読み込む（最後にVlogStore.addClipsがもう一度確かめる）。
/// - 同じものが2回選ばれていても1回として扱う。件数は理由ごとに数える（引き算で辻褄を合わせると、
///   同じ動画を2回選んだだけで「1件は追加済み」と出る）。
/// - 上限に入りきらない分は、読み込む前に断る。読んでから捨てていた頃は、残り5本の枠へ50本選ぶと、
///   入らない45本ぶんまでコピーとメタデータの読み取りを待たされていた。入れる分は選んだ順に先頭から取る。
///
/// - Parameters:
///   - existing: いまタイムラインにある動画の鍵
///   - currentCount: いまのタイムラインの本数
nonisolated func planAddition<Element, Key: Hashable>(
    requested: [Element],
    existing: Set<Key>,
    currentCount: Int,
    limit: Int = VlogLayout.maxClips,
    keyOf: (Element) -> Key?
) -> AdditionPlan<Element> {
    var seen = Set<Key>()
    var distinct: [Element] = []
    var alreadyAdded = 0
    for element in requested {
        guard let key = keyOf(element) else { distinct.append(element); continue }
        // 同じ選択の中の2回目は、数えずに黙って外す（タイムラインには無いので「追加済み」ではない）
        guard seen.insert(key).inserted else { continue }
        if existing.contains(key) { alreadyAdded += 1 } else { distinct.append(element) }
    }
    let room = max(0, limit - currentCount)
    let toLoad = Array(distinct.prefix(room))
    return AdditionPlan(toLoad: toLoad, alreadyAdded: alreadyAdded, overLimit: distinct.count - toLoad.count)
}
