import Foundation
import AVFoundation

/// Converts any incoming PCM buffer stream (any rate / channel count / sample format)
/// to 16 kHz mono Int16 — the format Whisper wants. Keeps one AVAudioConverter alive
/// per source format so resampling state is preserved across buffers.
final class StreamConverter {
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard buffer.frameLength > 0 else { return [] }

        if buffer.format == StreamConverter.targetFormat,
           let ch = buffer.int16ChannelData {
            return Array(UnsafeBufferPointer(start: ch[0], count: Int(buffer.frameLength)))
        }

        if converter == nil || sourceFormat != buffer.format {
            let newConverter = AVAudioConverter(from: buffer.format, to: StreamConverter.targetFormat)
            // AUVoiceIO on multi-mic Macs reports 5–7 discrete channels
            // (kAudioChannelLayoutTag_DiscreteInOrder). AVAudioConverter outputs
            // pure silence when downmixing a discrete layout unless channel 0 is mapped explicitly.
            if let newConverter, Self.shouldMapChannelZero(for: buffer.format) {
                newConverter.channelMap = [0]
            }
            converter = newConverter
            sourceFormat = buffer.format
        }
        guard let converter else { return [] }

        let ratio = StreamConverter.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: StreamConverter.targetFormat, frameCapacity: capacity) else { return [] }

        var fed = false
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, out.frameLength > 0, let ch = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
    }

    static func shouldMapChannelZero(for format: AVAudioFormat) -> Bool {
        if format.channelCount > 2 { return true }
        if format.channelCount > 1,
           let tag = format.channelLayout?.layoutTag,
           (tag & 0xFFFF0000) == kAudioChannelLayoutTag_DiscreteInOrder {
            return true
        }
        return false
    }
}
