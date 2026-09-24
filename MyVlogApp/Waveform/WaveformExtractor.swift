import AVFoundation
import Accelerate

/// 音の波形。値は 0…1 に正規化済み（Android: waveform/Waveform.kt の Waveform）。
/// `hasAudio` が false のときは音声トラックが無いことを表す。
nonisolated struct Waveform: Equatable, Sendable {
    let amplitudes: [Float]
    let hasAudio: Bool

    static let silent = Waveform(amplitudes: [], hasAudio: false)
}

/// 動画の音声をデコードして、区間ごとの音量（RMS）を取り出す。
///
/// キャッシュのキーはclip.idではなく素材そのものを指す`VlogClip.mediaCacheKey`。
/// 同じ動画を2回追加してもデコードをやり直さずに済み、AssetLoader/ThumbnailLoaderと
/// 同じキーで解放判定ができる（Android: 波形キャッシュをURIで持つのと同じ理由）。
actor WaveformExtractor {
    static let shared = WaveformExtractor()

    /// 取得できた波形（音声なしのWaveform.silentを含む）。
    ///
    /// 取得できなかった結果は覚えない。覚えていた頃は、一時的に読めなかっただけの動画
    /// （iCloud上でまだ落とせていない動画など）でも、アプリを終わらせるまで
    /// 「波形を取得できませんでした」のままだった。次にそのクリップを選んだときに取り直す
    /// （Android: requestWaveform。取り直している間は失敗の表示のまま、届いたら差し替わる）
    private var cache: [String: Waveform] = [:]

    /// いま走っているデコードと、その結果を待っている人の数。
    ///
    /// 【相乗り】actorのメソッドでも`await`で中断するため、その隙間に来た同じキーの呼び出しは
    /// キャッシュを素通りしてしまう。クリップを素早く行き来すると、同じ動画を何度も
    /// デコードし直すことになっていた（長い動画では数秒かかる処理）。
    ///
    /// 【取りやめ】待っている人が全員いなくなったら（＝画面が別のクリップへ移ったら）
    /// デコード自体を止める。誰も見ない波形を最後まで回すのは無駄なので。
    /// 人数を数えているのは、同じ素材を続けて選び直したとき（同じ動画を2回追加している場合など）に、
    /// 去っていく側が新しく来た側のデコードを巻き添えで止めてしまわないようにするため。
    ///
    /// 【id】止めた直後に同じキーで新しいデコードが始まることがある。そのとき、遅れて
    /// 終わった古いほうの後始末が新しいほうの登録を消してしまわないよう、世代を持たせて
    /// 「自分が登録したものか」を必ず確かめる。
    private struct Pending {
        let id: Int
        let task: Task<Waveform?, Never>
        var waiters: Int
    }
    private var pending: [String: Pending] = [:]
    private var nextPendingId = 0

    /// 波形の解像度（横方向の本数）の下限。タイムライン幅に対してこれくらいあれば粗く見えない
    static let minBuckets = 240

    /// 長い動画で波形1本が受け持つ時間の目安。
    /// 本数を尺に関係なく固定すると、10分の動画を数秒までズームしても表示範囲に
    /// 1本しか入らず、ズームしても情報が増えない（Android: WAVEFORM_TARGET_BUCKET_MS）。
    private static let targetBucketMs: Int64 = 100

    /// 本数の上限。集計用の配列とキャッシュを際限なく太らせないため
    private static let maxBuckets = 6000

    /// 尺に応じた波形の本数。短い動画は従来どおり`minBuckets`のまま
    /// （Android: waveformBucketsFor）
    static func buckets(forDurationMs durationMs: Int64) -> Int {
        let raw = Int(durationMs / targetBucketMs)
        return min(max(raw, minBuckets), maxBuckets)
    }

    /// - Returns: 音声トラックが無ければ`Waveform.silent`、読めなかった場合・取りやめた場合はnil
    func extract(asset: AVAsset, cacheKey: String, durationMs: Int64) async -> Waveform? {
        if let cached = cache[cacheKey] { return cached }

        let entry = join(cacheKey: cacheKey, asset: asset, durationMs: durationMs)
        // 呼び出し側（WaveformViewの.task）が取りやめたら、他に待っている人がいない場合に限り
        // デコードも止める。unstructuredなTaskは呼び出し側の取りやめが自動では伝わらないので、
        // ここで橋渡しする必要がある
        let result = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { await self.leave(cacheKey: cacheKey, id: entry.id) }
        }
        return settle(cacheKey: cacheKey, id: entry.id, result: result)
    }

    /// 進行中のデコードに相乗りする。無ければ始める
    private func join(cacheKey: String, asset: AVAsset, durationMs: Int64) -> Pending {
        if var existing = pending[cacheKey] {
            existing.waiters += 1
            pending[cacheKey] = existing
            return existing
        }
        nextPendingId += 1
        // computeはnonisolated（理由はcomputeのコメント）なので、このTaskはactorを塞がずに走る。
        // おかげで、デコード中でもleave/retainが届いて取りやめられる
        let entry = Pending(
            id: nextPendingId,
            task: Task { await Self.compute(asset: asset, durationMs: durationMs) },
            waiters: 1
        )
        pending[cacheKey] = entry
        return entry
    }

    /// 待つのをやめた人がいた。最後の1人が抜けたらデコードを止める
    private func leave(cacheKey: String, id: Int) {
        guard var entry = pending[cacheKey], entry.id == id else { return }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            pending.removeValue(forKey: cacheKey)
        } else {
            pending[cacheKey] = entry
        }
    }

    /// デコードが終わったので後始末をする。
    /// 自分が登録したものがまだ残っているときだけ結果をキャッシュへ入れる
    /// （取りやめた／解放された素材の結果は、途中までの値なので残さない）。
    private func settle(cacheKey: String, id: Int, result: Waveform?) -> Waveform? {
        guard pending[cacheKey]?.id == id else { return result }
        pending.removeValue(forKey: cacheKey)
        if let result { cache[cacheKey] = result }
        return result
    }

    /// タイムラインに残っていない素材の波形を捨てる（VlogStore.releaseUnusedMediaCaches）。
    /// 長い動画だと1本あたり数万バイトあり、残したままだともう画面に出ない波形を抱え続ける。
    func retain(only keys: Set<String>) {
        cache = cache.filter { keys.contains($0.key) }
        // 進行中のデコードも、もうタイムラインに無い素材なら止める。
        // pendingから消えるので、遅れて終わってもsettleがキャッシュへ入れない
        for (key, entry) in pending where !keys.contains(key) {
            entry.task.cancel()
            pending.removeValue(forKey: key)
        }
    }

    #if DEBUG
    /// 単体テスト（WaveformExtractorTests）から内部の様子を確かめるための覗き窓。
    /// キャッシュしている件数と、進行中のデコードの件数。
    var debugCounts: (cached: Int, pending: Int) { (cache.count, pending.count) }
    #endif

    // MARK: - Private

    /// 読み取り時のPCM形式。8kHzモノラルまで落としても、区間ごとの音量を見るには十分。
    private static let sampleRate: Double = 8000

    /// 音声をデコードして、区間ごとの音量を出す。
    ///
    /// **nonisolated（actorの外で走らせる）なのが要点。** 読み取りループ
    /// （`copyNextSampleBuffer`）は同期処理で一度も中断しないため、actor上で走らせると
    /// デコードが終わるまでactor自体が塞がる。すると外から`cancel()`を投げても、
    /// それを受けて後始末する`leave`/`retain`がキューで待たされ、取りやめが効かなかった。
    /// actorの状態には一切触らない処理なので、外へ出してしまえば
    /// デコード中でも取りやめを受け付けられる。
    ///
    /// 取りやめられた場合はnil（途中までの値は返さない）。
    private nonisolated static func compute(asset: AVAsset, durationMs: Int64) async -> Waveform? {
        guard durationMs > 0 else { return nil }
        // 読み込めなかった（壊れている・アクセスできない）のと、音声トラックが無いのとを分ける。
        // まとめてtry?で読んでいた頃は、読めない動画まで「音声なし」と表示され、そのまま覚えられていた
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            return nil
        }
        guard let track = audioTracks.first else { return .silent }

        let settings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:      16,
            AVLinearPCMIsFloatKey:       false,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey:       1,
            AVSampleRateKey:             Self.sampleRate
        ]

        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        // サンプルを全部ためてから割り振るのではなく、読みながら時間軸のバケツへ足し込む。
        //
        // 以前は全サンプルを配列にためており、メモリを抑えるため10分ぶんで打ち切っていた。
        // 打ち切ったぶんを尺全体の幅に引き伸ばして描いていたため、10分を超える動画では
        // **波形と時間軸がずれていた**（前半10分の波形が全体に広がって見える）。
        // 読みながら足し込めば、尺がどれだけ長くてもメモリはバケツの数だけで済み、
        // 時間軸ともずれない（Android: MediaCodecの出力を presentationTimeUs で
        // バケツへ足し込むのと同じ考え方）。
        let buckets = Self.buckets(forDurationMs: durationMs)
        var sums   = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        let durationSec = Double(durationMs) / 1000

        while let sampleBuffer = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sampleBuffer) }
            // 別のクリップへ移ったら、途中でも読むのをやめる。長い動画のデコードは数秒かかり、
            // 誰も見ない波形のために回し続けるのは無駄（取りやめの伝わり方はcomputeのコメント）
            if Task.isCancelled {
                reader.cancelReading()
                return nil
            }
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count  = length / MemoryLayout<Int16>.size
            guard count > 0 else { continue }

            var raw = [Int16](repeating: 0, count: count)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &raw)
            var floats = [Float](repeating: 0, count: count)
            vDSP_vflt16(raw, 1, &floats, 1, vDSP_Length(count))
            var scale: Float = 1.0 / 32768.0
            vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))

            let startSec = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            guard startSec.isFinite else { continue }
            accumulate(
                floats, startSec: startSec, durationSec: durationSec,
                buckets: buckets, sums: &sums, counts: &counts
            )
        }

        if reader.status == .reading { reader.cancelReading() }
        guard reader.status != .failed else { return nil }

        return Waveform(amplitudes: normalize(sums: sums, counts: counts), hasAudio: true)
    }

    /// 1つのサンプルバッファを、それが実際にまたがる時間のバケツへ振り分けて足し込む。
    ///
    /// バッファ全体を先頭の時刻だけで1つのバケツに入れると、バッファがバケツより
    /// 長いときに間のバケツが空のままになり、波形に等間隔の穴が空く。
    /// バケツの境目でサンプルを切り分けてから、まとまりごとにvDSPで二乗平均を取る
    /// （1サンプルずつSwiftのループで回すと長い動画で極端に遅くなる）。
    /// computeがnonisolatedなので、こちらもactorの外から呼べるようにしておく（actorの状態には触らない）
    private nonisolated static func accumulate(
        _ samples: [Float], startSec: Double, durationSec: Double,
        buckets: Int, sums: inout [Double], counts: inout [Int]
    ) {
        guard durationSec > 0, !samples.isEmpty else { return }
        let bucketSec = durationSec / Double(buckets)

        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var index = 0
            while index < samples.count {
                let time   = startSec + Double(index) / Self.sampleRate
                let bucket = min(buckets - 1, max(0, Int(time / bucketSec)))
                // このバケツの終わりまでに残っているサンプル数（最低1つは進めて止まらないようにする）
                let untilBucketEnd = (Double(bucket + 1) * bucketSec - time) * Self.sampleRate
                let span = min(samples.count - index, max(1, Int(untilBucketEnd.rounded(.up))))

                var meanSquare: Float = 0
                vDSP_measqv(base + index, 1, &meanSquare, vDSP_Length(span))
                sums[bucket]   += Double(meanSquare) * Double(span)
                counts[bucket] += span
                index += span
            }
        }
    }

    /// RMSへ直してから最大値で割る。
    ///
    /// 最後に0.6乗しているのは、生のRMSだと会話くらいの音量が全体の1割ほどの高さにしか
    /// ならず、波形がほぼ平らに見えてしまうため。音量の大小関係は保ったまま小さい音を
    /// 持ち上げている（Android: normalize）。
    /// computeがnonisolatedなので、こちらもactorの外から呼べるようにしておく（actorの状態には触らない）
    private nonisolated static func normalize(sums: [Double], counts: [Int]) -> [Float] {
        let rms = zip(sums, counts).map { sum, count in
            count == 0 ? 0 : (sum / Double(count)).squareRoot()
        }
        guard let peak = rms.max(), peak > 1e-5 else {
            return [Float](repeating: 0, count: sums.count)
        }
        return rms.map { Float(min(max(pow($0 / peak, 0.6), 0), 1)) }
    }
}
