import AVFoundation
import Accelerate

/// Extracts a normalised waveform (array of 0..1 Float values) from an AVAsset.
/// Results are cached by clip UUID.
actor WaveformExtractor {
    static let shared = WaveformExtractor()

    private var cache: [UUID: [Float]] = [:]

    func extract(asset: AVAsset, clipID: UUID, bins: Int = 240) async -> [Float] {
        if let cached = cache[clipID] { return cached }
        let result = await compute(asset: asset, bins: bins)
        cache[clipID] = result
        return result
    }

    // MARK: - Private

    private func compute(asset: AVAsset, bins: Int) async -> [Float] {
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return Array(repeating: 0, count: bins)
        }

        let settings: [String: Any] = [
            AVFormatIDKey:             kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:    16,
            AVLinearPCMIsFloatKey:     false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey:     1,
            AVSampleRateKey:           8000.0
        ]

        guard let reader = try? AVAssetReader(asset: asset) else {
            return Array(repeating: 0, count: bins)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            return Array(repeating: 0, count: bins)
        }

        var samples: [Float] = []
        samples.reserveCapacity(8000 * 60) // pre-alloc for ~60 s
        let maxSamples = 8000 * 600 // max 10 minutes to prevent unbounded memory growth

        while let sb = output.copyNextSampleBuffer() {
            defer { CMSampleBufferInvalidate(sb) }
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Int16>.size
            guard count > 0 else { continue }
            var raw = [Int16](repeating: 0, count: count)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &raw)
            var floats = [Float](repeating: 0, count: count)
            vDSP_vflt16(raw, 1, &floats, 1, vDSP_Length(count))
            var scale: Float = 1.0 / 32768.0
            vDSP_vsmul(floats, 1, &scale, &floats, 1, vDSP_Length(count))
            samples.append(contentsOf: floats)
            if samples.count >= maxSamples {
                break
            }
        }

        if reader.status == .reading {
            reader.cancelReading()
        }

        return binned(samples, bins: bins)
    }

    private func binned(_ samples: [Float], bins: Int) -> [Float] {
        guard !samples.isEmpty else { return Array(repeating: 0, count: bins) }
        let binSize = max(1, samples.count / bins)
        var result = [Float](repeating: 0, count: bins)
        samples.withUnsafeBufferPointer { buf in
            for i in 0..<bins {
                let start = i * binSize
                let end   = min(start + binSize, samples.count)
                guard start < samples.count else { break }
                var rms: Float = 0
                vDSP_measqv(buf.baseAddress! + start, 1, &rms, vDSP_Length(end - start))
                result[i] = pow(sqrt(rms), 0.6)
            }
        }
        if let peak = result.max(), peak > 0 {
            var divisor = peak
            vDSP_vsdiv(result, 1, &divisor, &result, 1, vDSP_Length(bins))
        }
        return result
    }
}
