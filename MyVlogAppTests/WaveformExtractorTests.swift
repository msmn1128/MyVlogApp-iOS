import AVFoundation
import Testing
@testable import MyVlogApp

/// 波形の解像度（本数）の決め方。Android: waveformBucketsFor
///
/// デコードそのものは実ファイルが要るのでテストできないが、「尺に応じて本数を増やす」
/// という判断だけは純粋な計算なのでここで守る。
@Suite("波形の解像度")
struct WaveformExtractorTests {

    @Test("短い動画は下限の本数のまま")
    func shortVideoUsesMinimum() {
        // 24秒以下は 240 本（240 * 100ms）
        #expect(WaveformExtractor.buckets(forDurationMs: 2_000) == 240)
        #expect(WaveformExtractor.buckets(forDurationMs: 24_000) == 240)
    }

    @Test("長い動画は100msに1本の割合で増える")
    func longVideoScalesWithDuration() {
        // 本数を固定にすると、長い動画を数秒までズームしても表示範囲に1本しか
        // 入らず、ズームしても情報が増えない
        #expect(WaveformExtractor.buckets(forDurationMs: 60_000) == 600)
        #expect(WaveformExtractor.buckets(forDurationMs: 300_000) == 3_000)
    }

    @Test("上限を超えては増やさない（配列とキャッシュを太らせないため）")
    func capsAtMaximum() {
        #expect(WaveformExtractor.buckets(forDurationMs: 600_000) == 6_000)
        #expect(WaveformExtractor.buckets(forDurationMs: 3_600_000) == 6_000)
    }

    @Test("尺が0や負でも下限を返す（0除算にしない）")
    func degenerateDuration() {
        #expect(WaveformExtractor.buckets(forDurationMs: 0) == 240)
        #expect(WaveformExtractor.buckets(forDurationMs: -1) == 240)
    }

    @Test("音声なしの波形は hasAudio が false")
    func silentWaveform() {
        #expect(Waveform.silent.hasAudio == false)
        #expect(Waveform.silent.amplitudes.isEmpty)
    }
}

// =====================================================================================
// キャッシュと進行中デコードの管理。
//
// 共有インスタンス（.shared）ではなく毎回新しいWaveformExtractorを作るのは、
// テスト同士が同じキャッシュを見て順番に依存しないようにするため。
// =====================================================================================

@Suite("波形のキャッシュと解放")
struct WaveformExtractorCacheTests {

    /// 音声トラックの無い動画でも結果（Waveform.silent）はキャッシュされるので、
    /// キャッシュの出入りを確かめるにはこれで足りる
    private func makeAsset() async throws -> (asset: AVURLAsset, url: URL) {
        let url = try await TestVideoFactory.makeSolidColorVideo(seconds: 1)
        return (AVURLAsset(url: url), url)
    }

    @Test("一度読んだ素材はキャッシュされ、2回目はデコードし直さない")
    func cachesResult() async throws {
        let extractor = WaveformExtractor()
        let (asset, url) = try await makeAsset()
        defer { TestVideoFactory.remove(url) }

        let first  = await extractor.extract(asset: asset, cacheKey: "k", durationMs: 1_000)
        let second = await extractor.extract(asset: asset, cacheKey: "k", durationMs: 1_000)

        #expect(first == second)
        let counts = await extractor.debugCounts
        #expect(counts.cached == 1)
        #expect(counts.pending == 0, "デコードが終わったのに進行中のまま残っている")
    }

    @Test("同じ素材を同時に要求しても、デコードは1回だけ")
    func concurrentRequestsShareOneDecode() async throws {
        // 回帰テスト: actorのメソッドでもawaitで中断するため、その隙間に来た同じキーの
        // 要求がキャッシュを素通りして二重にデコードしていた
        let extractor = WaveformExtractor()
        let (asset, url) = try await makeAsset()
        defer { TestVideoFactory.remove(url) }

        async let a = extractor.extract(asset: asset, cacheKey: "k", durationMs: 1_000)
        async let b = extractor.extract(asset: asset, cacheKey: "k", durationMs: 1_000)
        async let c = extractor.extract(asset: asset, cacheKey: "k", durationMs: 1_000)
        let results = await [a, b, c]

        #expect(results[0] == results[1] && results[1] == results[2])
        let counts = await extractor.debugCounts
        #expect(counts.cached == 1, "同じ素材が複数回キャッシュされている")
        #expect(counts.pending == 0)
    }

    @Test("タイムラインに残っていない素材のキャッシュは捨てる")
    func retainDropsUnusedKeys() async throws {
        let extractor = WaveformExtractor()
        let (asset, url) = try await makeAsset()
        defer { TestVideoFactory.remove(url) }

        _ = await extractor.extract(asset: asset, cacheKey: "keep", durationMs: 1_000)
        _ = await extractor.extract(asset: asset, cacheKey: "drop", durationMs: 1_000)
        #expect(await extractor.debugCounts.cached == 2)

        await extractor.retain(only: ["keep"])

        #expect(await extractor.debugCounts.cached == 1, "残すはずのキーまで消えている、または捨て損ねている")
    }

    @Test("全部解放すればキャッシュも進行中のデコードも空になる")
    func retainNothingClearsEverything() async throws {
        let extractor = WaveformExtractor()
        let (asset, url) = try await makeAsset()
        defer { TestVideoFactory.remove(url) }

        _ = await extractor.extract(asset: asset, cacheKey: "k", durationMs: 1_000)
        await extractor.retain(only: [])

        let counts = await extractor.debugCounts
        #expect(counts.cached == 0)
        #expect(counts.pending == 0)
    }
}
