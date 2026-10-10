// DRSync.swift
// How the DR results travel through Jellyfin (Display Preferences "amplifin-dr", client
// "amplifin", CustomPrefs). A song is 18 bytes: its 32 hex digit id as 16 bytes, then the
// DR in tenths of dB as a big-endian Int16. Entries are cut in chunks of 1250 (22500
// bytes, 30000 base64 characters) stored as `dr0`, `dr1`, …; `drCount` is the number of
// chunks and `drDate` the upload time (ISO 8601).

import Foundation

enum DRSyncCoding {
    static let entriesPerChunk = 1250
    private static let entrySize = 18

    /// DR rounded to a tenth of dB, as it is sent.
    static func tenths(_ value: Double) -> Int {
        Int(max(Double(Int16.min), min(Double(Int16.max), (value * 10).rounded())))
    }

    static func encode(_ results: [String: DRResult]) -> [String] {
        // Sorted, so the same results always give the same text.
        let entries = results.keys.sorted().compactMap { id -> Data? in
            guard let idBytes = bytes(ofHexId: id) else { return nil }
            let tenths = UInt16(bitPattern: Int16(tenths(results[id]!.value)))
            return Data(idBytes + [UInt8(tenths >> 8), UInt8(tenths & 0xff)])
        }
        return stride(from: 0, to: entries.count, by: entriesPerChunk).map { start in
            entries[start..<min(start + entriesPerChunk, entries.count)]
                .reduce(into: Data()) { $0.append($1) }
                .base64EncodedString()
        }
    }

    /// Id → tenths of dB. A damaged chunk is skipped, not fatal.
    static func decode(chunks: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for chunk in chunks {
            guard let data = Data(base64Encoded: chunk) else { continue }
            let bytes = [UInt8](data)
            var offset = 0
            while offset + entrySize <= bytes.count {
                let id = bytes[offset..<offset + 16].map { String(format: "%02x", $0) }.joined()
                let raw = UInt16(bytes[offset + 16]) << 8 | UInt16(bytes[offset + 17])
                result[id] = Int(Int16(bitPattern: raw))
                offset += entrySize
            }
        }
        return result
    }

    /// The 16 bytes of a Jellyfin id (32 hex digits, dashes allowed), nil if it isn't one.
    private static func bytes(ofHexId id: String) -> [UInt8]? {
        let hex = Array(id.lowercased().replacingOccurrences(of: "-", with: "").utf8)
        guard hex.count == 32 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(16)
        for i in stride(from: 0, to: 32, by: 2) {
            guard let high = nibble(hex[i]), let low = nibble(hex[i + 1]) else { return nil }
            out.append(high << 4 | low)
        }
        return out
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case 48...57: return char - 48
        case 97...102: return char - 87
        default: return nil
        }
    }
}
