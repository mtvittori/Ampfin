// DRMeter.swift
// The measurement itself, a port of ffmpeg's `drmeter` filter (libavfilter/af_drmeter.c,
// the "TT DR" of foobar2000's foo_dr_meter): same 3 s blocks, same 1/32768 histograms
// for peaks and RMS, same "second peak over the RMS of the loudest 20%" rule, so the
// numbers match ffmpeg's. Nothing here touches the main actor.

import Accelerate
import AVFoundation
import Foundation

enum DRMeterError: LocalizedError {
    case unreadable(String)
    case tooShort
    case silent

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason): return "File non leggibile (\(reason))"
        case .tooShort: return "Brano troppo corto"
        case .silent: return "Brano silenzioso"
        }
    }
}

enum DRMeter {
    private static let bins = 32768
    private static let blockSeconds = 3.0

    /// DR in dB (unrounded) of an audio file, averaged over its channels. Cooperative:
    /// when called inside a cancelled Task it stops and throws `CancellationError`.
    static func measure(fileURL: URL) throws -> Double {
        try measure(fileURL: fileURL, shouldCancel: { Task.isCancelled })
    }

    /// `shouldCancel` is for callers on a plain thread, where `Task.isCancelled` means nothing.
    static func measure(fileURL: URL, shouldCancel: () -> Bool) throws -> Double {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw DRMeterError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard channelCount > 0, format.sampleRate > 0 else { throw DRMeterError.unreadable("formato") }

        let blockLength = Int(format.sampleRate * blockSeconds)
        let channels = (0..<channelCount).map { _ in Channel() }
        // A couple of seconds per read: big enough to be fast, small enough for 24/192 files.
        let chunkFrames = AVAudioFrameCount(max(4096, Int(format.sampleRate) * 2))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw DRMeterError.unreadable("memoria")
        }

        while file.framePosition < file.length {
            if shouldCancel() { throw CancellationError() }
            var failure: Error?
            var frames = 0
            var reachedEnd = false
            autoreleasepool {
                do {
                    try file.read(into: buffer, frameCount: chunkFrames)
                    frames = Int(buffer.frameLength)
                } catch let error as NSError where error.domain == NSOSStatusErrorDomain && error.code == -39 {
                    // Some containers (E-AC-3, FLAC in MP4) report eofErr on the last packet
                    // even though the length said there was more: the file is simply over.
                    reachedEnd = true
                } catch {
                    failure = error
                }
            }
            if let failure { throw DRMeterError.unreadable(failure.localizedDescription) }
            if reachedEnd { break }
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for c in 0..<channelCount {
                channels[c].feed(data[c], count: frames, blockLength: blockLength)
            }
        }

        var total = 0.0
        var measured = 0
        for channel in channels {
            if let dr = channel.dynamicRange() {
                total += dr
                measured += 1
            }
        }
        if measured == 0 {
            throw channels.allSatisfy({ $0.blockCount == 0 }) ? DRMeterError.tooShort : DRMeterError.silent
        }
        return total / Double(measured)
    }

    /// Runs `measure` on a utility thread instead of the cooperative pool (it takes seconds
    /// and would starve it), and stops early when the calling task is cancelled.
    static func measureAsync(fileURL: URL, qos: DispatchQoS.QoSClass = .utility) async throws -> Double {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: qos).async {
                    do {
                        continuation.resume(returning: try measure(fileURL: fileURL, shouldCancel: { flag.isSet }))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.set()
        }
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Per channel state of af_drmeter: the block being filled and the histograms of the finished ones.
    private final class Channel {
        private var sum = 0.0
        private var peak: Float = 0
        private var samplesInBlock = 0
        private(set) var blockCount = 0
        private var peaks = [UInt32](repeating: 0, count: DRMeter.bins + 1)
        private var rms = [UInt32](repeating: 0, count: DRMeter.bins + 1)

        func feed(_ samples: UnsafePointer<Float>, count: Int, blockLength: Int) {
            var offset = 0
            while offset < count {
                let take = min(count - offset, blockLength - samplesInBlock)
                var squares: Float = 0
                var top: Float = 0
                vDSP_svesq(samples + offset, 1, &squares, vDSP_Length(take))
                vDSP_maxmgv(samples + offset, 1, &top, vDSP_Length(take))
                sum += Double(squares)
                peak = max(peak, top)
                samplesInBlock += take
                offset += take
                if samplesInBlock >= blockLength { finishBlock() }
            }
        }

        private func finishBlock() {
            let level = Float((2 * sum / Double(samplesInBlock)).squareRoot())
            let bins = DRMeter.bins
            rms[Self.bin(level * Float(bins), bins)] += 1
            peaks[Self.bin(peak * Float(bins), bins)] += 1
            peak = 0
            sum = 0
            samplesInBlock = 0
            blockCount += 1
        }

        /// lrintf + clip, like ffmpeg.
        private static func bin(_ value: Float, _ bins: Int) -> Int {
            guard value.isFinite else { return bins }
            return min(max(Int(value.rounded(.toNearestOrEven)), 0), bins)
        }

        /// nil when there is nothing to measure (no data, or silence).
        func dynamicRange() -> Double? {
            // ffmpeg takes the 20% from the full blocks only, then adds the partial one.
            let last = max(1, Int((0.2 * Float(blockCount)).rounded(.toNearestOrEven)))
            if samplesInBlock > 0 { finishBlock() }
            guard blockCount > 0 else { return nil }
            let bins = DRMeter.bins

            var secondPeakBin = bins
            var seenFirst = false
            for i in stride(from: bins, through: 0, by: -1) where peaks[i] > 0 {
                if seenFirst || peaks[i] > 1 {
                    secondPeakBin = i
                    break
                }
                seenFirst = true
            }
            let secondPeak = Float(secondPeakBin) / Float(bins)

            var rmsSum: Float = 0
            var counted = 0
            var i = bins
            while i >= 0, counted < last {
                if rms[i] > 0 {
                    let level = Float(i) / Float(bins)
                    rmsSum += level * level * Float(rms[i])
                    counted += Int(rms[i])
                }
                i -= 1
            }

            guard secondPeak > 0, rmsSum > 0 else { return nil }
            return Double(20 * log10f(secondPeak / (rmsSum / Float(last)).squareRoot()))
        }
    }
}
