import Foundation

/// 配列を1件ずつ読み、読めない要素だけを飛ばして数える（Android: ClipStore.readableClips / readProjects）。
///
/// 保存データの配列を`[T]`のまま読むと、1件でも壊れていれば配列全体が読めない。
/// 自動保存なら前回の続きが丸ごと復元されず、そのまま次の自動保存で空の一覧が書き戻されて消える。
/// 一時保存の一覧なら一覧が空に見え、次に保存したとき残りの全件が上書きされて消える。
/// 壊れた1件のせいで残り全部を巻き添えにしないよう、読めた分だけを活かす。
///
/// 可変状態を持たない値型なので、VlogClipと同じくnonisolatedにしてある。
nonisolated struct LossyList<Element: Decodable>: Decodable {
    var elements: [Element]
    /// 読めずに飛ばした件数
    var droppedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var dropped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
                continue
            }
            // 読めなかった要素は、JSONDecoderでは読み位置が進まないまま残る。
            // 何でも受け取る型で読み捨てて次の要素へ進める（nullはそちらでも読めないのでdecodeNilで）
            dropped += 1
            if (try? container.decode(SkippedElement.self)) == nil,
               (try? container.decodeNil()) != true {
                // どちらでも進められない要素は想定していないが、進めないまま回り続けないよう打ち切る
                break
            }
        }
        self.elements = elements
        self.droppedCount = dropped
    }
}

/// 読み捨て用。中身を見ずに受け取るので、どんな形の要素でも読めたことになる
private nonisolated struct SkippedElement: Decodable {
    init(from decoder: Decoder) throws {}
}
