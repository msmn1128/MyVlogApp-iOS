import Foundation
import Testing
@testable import MyVlogApp

/// ファイル取り込みの重複判定に使う指紋（FileContentKey）。
///
/// フォトライブラリ由来は識別子で同一と分かるが、ファイル取り込みは選ぶたびに
/// 別名でコピーするため、中身から見分けるしかない。
@Suite("ファイルの指紋")
struct FileContentKeyTests {

    /// 指定した中身のファイルを一時ディレクトリへ作る
    private func makeFile(_ data: Data, name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// 先頭64KB・末尾64KBしか読まないので、それを跨ぐ大きさで試す
    private func payload(head: UInt8, filler: UInt8, tail: UInt8, size: Int = 200 * 1024) -> Data {
        var data = Data(repeating: filler, count: size)
        data[0] = head
        data[size - 1] = tail
        return data
    }

    @Test("中身が同じなら、別の名前でコピーしても同じ指紋になる")
    func sameContentSameKey() throws {
        // 取り込みはDocumentsへ「UUID_元の名前」でコピーするので、名前は必ず違う
        let data = payload(head: 1, filler: 2, tail: 3)
        let a = try makeFile(data, name: "a-\(UUID().uuidString).mov")
        let b = try makeFile(data, name: "b-\(UUID().uuidString).mov")
        defer { TestVideoFactory.remove(a, b) }

        let keyA = FileContentKey.make(for: a)
        #expect(keyA != nil)
        #expect(keyA == FileContentKey.make(for: b))
    }

    @Test("先頭が違えば別の指紋になる")
    func differentHeadDiffers() throws {
        let a = try makeFile(payload(head: 1, filler: 2, tail: 3))
        let b = try makeFile(payload(head: 9, filler: 2, tail: 3))
        defer { TestVideoFactory.remove(a, b) }

        #expect(FileContentKey.make(for: a) != FileContentKey.make(for: b))
    }

    @Test("末尾が違えば別の指紋になる")
    func differentTailDiffers() throws {
        // 末尾も読んでいることの確認。動画はここにインデックス（moov等）を持つので効く
        let a = try makeFile(payload(head: 1, filler: 2, tail: 3))
        let b = try makeFile(payload(head: 1, filler: 2, tail: 9))
        defer { TestVideoFactory.remove(a, b) }

        #expect(FileContentKey.make(for: a) != FileContentKey.make(for: b))
    }

    @Test("長さが違えば別の指紋になる")
    func differentSizeDiffers() throws {
        // 先頭も末尾も同じで長さだけ違うファイル（書き出しが途中で切れたものなど）を
        // 取り違えないよう、サイズもハッシュに混ぜてある
        let a = try makeFile(payload(head: 1, filler: 2, tail: 3, size: 200 * 1024))
        let b = try makeFile(payload(head: 1, filler: 2, tail: 3, size: 300 * 1024))
        defer { TestVideoFactory.remove(a, b) }

        #expect(FileContentKey.make(for: a) != FileContentKey.make(for: b))
    }

    @Test("64KBに満たない小さなファイルでも指紋が取れる")
    func smallFile() throws {
        // 先頭を読んだ時点で全部読み終わっている経路（末尾は読まない）
        let a = try makeFile(Data(repeating: 7, count: 100))
        let b = try makeFile(Data(repeating: 7, count: 100))
        let c = try makeFile(Data(repeating: 8, count: 100))
        defer { TestVideoFactory.remove(a, b, c) }

        #expect(FileContentKey.make(for: a) != nil)
        #expect(FileContentKey.make(for: a) == FileContentKey.make(for: b))
        #expect(FileContentKey.make(for: a) != FileContentKey.make(for: c))
    }

    @Test("空のファイルでも落ちない")
    func emptyFile() throws {
        let url = try makeFile(Data())
        defer { TestVideoFactory.remove(url) }
        #expect(FileContentKey.make(for: url) != nil)
    }

    @Test("開けないファイルはnil（重複判定を諦める）")
    func missingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mov")
        #expect(FileContentKey.make(for: missing) == nil)
    }
}
