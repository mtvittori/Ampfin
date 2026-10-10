import AVFoundation
import Foundation
import Testing
@testable import Ampfin

struct DRMeterTests {
    /// 10 blocks of 3 s, mono 8 kHz: two loud sines (amplitude 0.2), eight quiet ones
    /// (0.05), two of the quiet ones with a 0.8 spike. A sine block has RMS (as the filter
    /// computes it) equal to its amplitude, so DR = 20 log10(0.8 / 0.2) = 12.04 dB.
    @Test func measuresKnownSignal() throws {
        let rate = 8000
        let block = 3 * rate
        var samples: [Float] = []
        for index in 0..<10 {
            let amplitude: Float = index < 2 ? 0.2 : 0.05
            for n in 0..<block {
                samples.append(amplitude * sin(2 * .pi * 440 * Float(n) / Float(rate)))
            }
            if index == 5 || index == 6 { samples[index * block + 1] = 0.8 }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dr-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeWav(samples, rate: Double(rate), to: url)

        let dr = try DRMeter.measure(fileURL: url)
        #expect(abs(dr - 12.04) < 0.1)
    }

    @Test func silenceThrows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dr-silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeWav([Float](repeating: 0, count: 8000 * 10), rate: 8000, to: url)
        #expect(throws: DRMeterError.self) { try DRMeter.measure(fileURL: url) }
    }

    @Test func syncCodingRoundTrips() {
        let date = Date(timeIntervalSince1970: 0)
        var results: [String: DRResult] = [:]
        for i in 0..<3000 {
            results[String(format: "%032x", i * 7919 + 1)] = DRResult(value: Double(i % 200) / 10 - 3.04, measured: date)
        }
        let chunks = DRSyncCoding.encode(results)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { $0.count <= 30000 })
        let decoded = DRSyncCoding.decode(chunks: chunks)
        #expect(decoded.count == results.count)
        for (id, result) in results {
            #expect(decoded[id] == DRSyncCoding.tenths(result.value))
        }
    }

    private func writeWav(_ samples: [Float], rate: Double, to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }
}
