// IPodConverter.swift
// What the iPod sync does to a file: lossless → AAC in an .m4a with iTunes tags (AVFoundation,
// Apple's encoder), and the album cover as a small baseline JPEG, which is what Rockbox can
// read. Nothing here touches the main actor or the app's state.

#if os(macOS)
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The tags written into a converted file.
struct IPodTags: Sendable {
    var title: String
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var trackTotal: Int?
    var disc: Int?
    var discTotal: Int?
}

enum IPodConverterError: LocalizedError {
    case noAudio
    case readerFailed(String)
    case writerFailed(String)
    case badImage

    var errorDescription: String? {
        switch self {
        case .noAudio: return "il file non ha tracce audio leggibili"
        case .readerFailed(let reason): return "lettura fallita (\(reason))"
        case .writerFailed(let reason): return "conversione fallita (\(reason))"
        case .badImage: return "copertina non leggibile"
        }
    }
}

enum IPodConverter {
    /// Codecs that lose nothing: these are the ones converted to AAC.
    static func isLossless(url: URL, containerHint: String?) async -> Bool {
        let container = containerHint?.lowercased() ?? url.pathExtension.lowercased()
        if ["flac", "alac", "wav", "wave", "aif", "aiff", "ape", "wv", "wavpack"].contains(container) { return true }
        // An .m4a can hold ALAC or AAC: look inside.
        guard ["m4a", "mp4"].contains(container) else { return false }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let descriptions = try? await track.load(.formatDescriptions) else { return false }
        return descriptions.contains {
            let format = CMFormatDescriptionGetMediaSubType($0)
            return format == kAudioFormatAppleLossless || format == kAudioFormatLinearPCM || format == kAudioFormatFLAC
        }
    }

    // MARK: - Audio

    /// Decodes `source` and writes it as AAC at `bitrate` (bits per second) into `destination`.
    /// Keeps the sample rate up to 48 kHz, otherwise 44.1 kHz; stereo (a mono file stays mono).
    static func convertToAAC(source: URL, destination: URL, bitrate: Int, tags: IPodTags) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw IPodConverterError.noAudio }

        var sourceRate = 44_100, sourceChannels = 2
        if let description = try await track.load(.formatDescriptions).first,
           let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            if format.mSampleRate > 0 { sourceRate = Int(format.mSampleRate) }
            if format.mChannelsPerFrame > 0 { sourceChannels = Int(format.mChannelsPerFrame) }
        }
        let rate = sourceRate <= 48_000 ? sourceRate : 44_100
        let channels = min(sourceChannels, 2)

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: asset)
        // 32-bit float: a 24-bit source reaches the encoder untouched.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ])
        guard reader.canAdd(output) else { throw IPodConverterError.readerFailed("formato non supportato") }
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            // The bitrate is for a stereo pair.
            AVEncoderBitRateKey: channels == 1 ? bitrate / 2 : bitrate,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw IPodConverterError.writerFailed("formato non supportato") }
        writer.add(input)
        writer.metadata = metadata(for: tags)

        guard reader.startReading() else {
            throw IPodConverterError.readerFailed(reader.error?.localizedDescription ?? "sconosciuto")
        }
        guard writer.startWriting() else {
            throw IPodConverterError.writerFailed(writer.error?.localizedDescription ?? "sconosciuto")
        }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump(reader: reader, output: output, writer: writer, input: input)
        try await withTaskCancellationHandler {
            try await pump.run()
        } onCancel: {
            pump.cancel()
        }
    }

    /// Moves the decoded samples to the encoder, off the main thread, as the writer asks for them.
    private final class Pump: @unchecked Sendable {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        private let queue = DispatchQueue(label: "ampfin.ipod.convert")

        init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, writer: AVAssetWriter, input: AVAssetWriterInput) {
            self.reader = reader; self.output = output; self.writer = writer; self.input = input
        }

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var finished = false

        /// Resumes the waiting `run` once, whoever gets there first: the end of the samples or a cancel.
        private func finish() {
            lock.lock()
            let waiting = continuation
            continuation = nil
            finished = true
            lock.unlock()
            waiting?.resume()
        }

        func cancel() {
            reader.cancelReading()
            writer.cancelWriting()
            // The writer won't ask for more samples after this: nobody else would wake `run`.
            finish()
        }

        func run() async throws {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                lock.lock()
                if finished {
                    lock.unlock()
                    done.resume()
                    return
                }
                continuation = done
                lock.unlock()
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    var ended = false
                    while input.isReadyForMoreMediaData && !ended {
                        if let buffer = output.copyNextSampleBuffer() {
                            if !input.append(buffer) { ended = true }
                        } else {
                            ended = true
                        }
                    }
                    if ended {
                        // After a cancel the writer is no longer writing, and finishing its input would throw.
                        if writer.status == .writing { input.markAsFinished() }
                        finish()
                    }
                }
            }
            if Task.isCancelled { cancel(); throw CancellationError() }
            if reader.status == .failed {
                writer.cancelWriting()
                throw IPodConverterError.readerFailed(reader.error?.localizedDescription ?? "sconosciuto")
            }
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw IPodConverterError.writerFailed(writer.error?.localizedDescription ?? "sconosciuto")
            }
        }
    }

    // MARK: - Tags

    /// iTunes-style atoms, which is what Rockbox's m4a reader looks for.
    private static func metadata(for tags: IPodTags) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func text(_ identifier: AVMetadataIdentifier, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = value as NSString
            items.append(item)
        }
        func raw(_ identifier: AVMetadataIdentifier, _ bytes: [UInt8]) {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.dataType = kCMMetadataBaseDataType_RawData as String
            item.value = Data(bytes) as NSData
            items.append(item)
        }
        func be16(_ value: Int?) -> [UInt8] {
            let clamped = UInt16(max(0, min(Int(UInt16.max), value ?? 0)))
            return [UInt8(clamped >> 8), UInt8(clamped & 0xff)]
        }

        text(.iTunesMetadataSongName, tags.title)
        text(.iTunesMetadataArtist, tags.artist)
        text(.iTunesMetadataAlbum, tags.album)
        text(.iTunesMetadataAlbumArtist, tags.albumArtist)
        text(.iTunesMetadataUserGenre, tags.genre)
        if let year = tags.year, year > 0 { text(.iTunesMetadataReleaseDate, String(year)) }
        // trkn: 2 bytes of padding, number, total, 2 bytes of padding. disk: padding, number, total.
        if let number = tags.trackNumber, number > 0 {
            raw(.iTunesMetadataTrackNumber, [0, 0] + be16(number) + be16(tags.trackTotal) + [0, 0])
        }
        if let disc = tags.disc, disc > 0 {
            raw(.iTunesMetadataDiscNumber, [0, 0] + be16(disc) + be16(tags.discTotal))
        }
        return items
    }

    // MARK: - Cover

    /// A JPEG of at most `side` pixels on its longer side. Rockbox can't read progressive
    /// JPEGs, so that is spelled out; ImageIO writes baseline by default.
    static func coverJPEG(from data: Data, side: Int = 200) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary) else { throw IPodConverterError.badImage }

        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw IPodConverterError.badImage
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyJFIFDictionary: [kCGImagePropertyJFIFIsProgressive: false],
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw IPodConverterError.badImage }
        return result as Data
    }
}
#endif
