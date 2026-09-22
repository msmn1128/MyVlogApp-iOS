import CryptoKit
import Foundation

/// ファイル取り込みのクリップが「同じ動画か」を見分けるための指紋。
///
/// フォトライブラリ由来のクリップはPHAssetのlocalIdentifierで同一と分かるが、ファイル取り込みは
/// 選ぶたびにDocumentsへ`UUID_元の名前`でコピーするため、パスもUUIDも手がかりにならない。
/// そのため同じ動画を2回選んでも重複を検知できず、タイムラインに同じ映像が2本並んでいた
/// （コード内で「既知の制約」として残していたもの）。
///
/// 中身をまるごとハッシュすると数GBの動画では現実的な時間に収まらないので、
/// **ファイルサイズ + 先頭64KB + 末尾64KB** から作る。動画ファイルは先頭にヘッダ、
/// 末尾にインデックス（MP4のmoov等）を持ち、映像が違えばサイズもまず一致しないため、
/// この3点が揃って中身だけ違うことは実用上起こらない。
///
/// 仮に取り違えたとしても、起きるのは「追加済みとしてスキップされる」ことだけで、
/// 既にあるデータが壊れることはない。
///
/// 可変状態を持たない純粋関数なので、@MainActorがプロジェクト全体の既定になっていても
/// どこからでも呼べるようnonisolatedにしてある（取り込みは並列タスクから呼ぶ）。
nonisolated enum FileContentKey {

    /// 先頭・末尾からそれぞれ読む量
    private static let sampleBytes = 64 * 1024

    /// - Returns: 16進の指紋。ファイルを開けない場合はnil（そのときは重複判定を諦める）
    static func make(for url: URL) -> String? {
        guard let size = fileSize(of: url) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        // サイズも混ぜる。先頭と末尾が同じで長さだけ違うファイル（書き出しが途中で
        // 切れたものなど）を別物として扱えるようにするため
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }

        // 中身が空のファイルではreadがnilを返す。その場合もサイズだけで指紋は作れるので、
        // 読めなかったぶんは「空」として扱い、nilを返して判定を諦めることはしない
        hasher.update(data: (try? handle.read(upToCount: sampleBytes)) ?? nil ?? Data())

        // 小さいファイルは先頭を読んだ時点で全部読めているので、末尾は読まない
        if size > Int64(sampleBytes) {
            let tailOffset = UInt64(size - Int64(sampleBytes))
            guard (try? handle.seek(toOffset: tailOffset)) != nil else { return nil }
            hasher.update(data: (try? handle.readToEnd()) ?? nil ?? Data())
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func fileSize(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }
}
