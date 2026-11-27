import Foundation

/// 16-bit PCM mono WAV built in memory, at the captured sample rate. Samples are clamped to
/// [-1, 1]; NaN becomes silence. Empty audio is rejected, so a header-only file is never uploaded.
public enum WAVEncoder {
    public static func encode(_ audio: CapturedAudio) throws -> Data {
        guard !audio.samples.isEmpty else { throw TranscriptionError.unsupportedAudio }
        let rate = audio.sampleRate.rounded()
        guard rate.isFinite, rate >= 1, rate <= Double(UInt32.max / 2) else { throw TranscriptionError.unsupportedAudio }
        let dataBytes = audio.samples.count * 2
        guard dataBytes <= Int(UInt32.max) - 36 else { throw TranscriptionError.unsupportedAudio }

        var wav = Data(capacity: 44 + dataBytes)
        wav.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes), to: &wav)
        wav.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16), to: &wav)       // fmt chunk size
        append(UInt16(1), to: &wav)        // linear PCM
        append(UInt16(1), to: &wav)        // mono
        append(UInt32(rate), to: &wav)
        append(UInt32(rate) * 2, to: &wav) // byte rate
        append(UInt16(2), to: &wav)        // block align
        append(UInt16(16), to: &wav)       // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes), to: &wav)

        let pcm = audio.samples.map { sample -> Int16 in
            guard !sample.isNaN else { return 0 }
            return Int16((max(-1, min(1, sample)) * 32767).rounded()).littleEndian
        }
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
        return wav
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
