import Foundation
import SwiftUI
import UniformTypeIdentifiers

// INTERFACE CONTRACT shared by the import engine and the UI (DR ranking / album comparison).
// Names and signatures above must not change; the engine is below.

/// What an import did, for the message shown after it.
struct DRImportResult: Equatable {
    /// Songs whose DR was added or replaced.
    var imported = 0
    /// Rows already identical to what the app has.
    var unchanged = 0
    /// Rows whose id isn't a song of this library (or unreadable rows).
    var skipped = 0
}

enum DRImportError: LocalizedError {
    case unreadable(String)
    var errorDescription: String? {
        switch self {
        case .unreadable(let why): return "File non leggibile: \(why)"
        }
    }
}

extension DRStore {
    /// Imports DR values from a file the user picked (security-scoped URL from fileImporter):
    /// JSON `{id: dr}` (server script dr-ampfin.json), JSON `{id: {value, measured}}` (Ampfin export)
    /// or CSV with an `id` column and a `DR esatto` or `DR` column (dr-classifica.csv).
    /// Imported values win over the ones already here; the result is saved and synced to Jellyfin.
    func importFile(at url: URL, knownIds: Set<String>) throws -> DRImportResult {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DRImportError.unreadable(error.localizedDescription)
        }
        return try importData(data, knownIds: knownIds)
    }

    /// The part of importFile after the read, so tests don't need files.
    func importData(_ data: Data, knownIds: Set<String>) throws -> DRImportResult {
        let parsed = try DRImportParser.parse(data)
        let known = Set(knownIds.compactMap(DRImportParser.normalizedId))
        let now = Date()

        // A file can name the same song twice: the last row wins.
        var latest: [String: DRImportParser.Row] = [:]
        for row in parsed.rows { latest[row.id] = row }

        var result = DRImportResult()
        result.skipped = parsed.invalid
        var updates: [String: DRResult] = [:]
        for (id, row) in latest {
            if !known.isEmpty, !known.contains(id) {
                result.skipped += 1
            } else if let old = results[id], (old.value * 100).rounded() == (row.value * 100).rounded() {
                result.unchanged += 1
            } else {
                updates[id] = DRResult(value: row.value, measured: row.measured ?? now)
            }
        }
        result.imported = updates.count
        // One change for the whole file: thousands of record() calls would redraw the UI each time.
        recordMany(updates)
        return result
    }

    /// The JSON written by "Esporta DR": `{id: {value, measured}}`, readable by importFile.
    /// `measured` is an ISO 8601 string.
    func exportData() throws -> Data {
        let formatter = ISO8601DateFormatter()
        let object = results.mapValues { ["value": $0.value, "measured": formatter.string(from: $0.measured)] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// The exported DR file, for fileExporter.
struct DRExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static var suggestedName: String {
        "amplifin DR \(Date().formatted(.iso8601.year().month().day()))"
    }
}

// MARK: - Parsing

/// Reads the three file formats into rows; knows nothing about the store.
enum DRImportParser {
    struct Row {
        let id: String
        let value: Double
        /// Only when the file says when it was measured.
        let measured: Date?
    }

    /// `invalid` counts the entries that couldn't be read (bad id, missing or NaN value).
    static func parse(_ data: Data) throws -> (rows: [Row], invalid: Int) {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }  // UTF-8 BOM
        guard let first = bytes.first(where: { !isSpace($0) }) else {
            throw DRImportError.unreadable("il file è vuoto")
        }
        let parsed = first == UInt8(ascii: "{") ? try parseJSON(bytes) : try parseCSV(bytes)
        guard !parsed.rows.isEmpty || parsed.invalid > 0 else {
            throw DRImportError.unreadable("nessun valore DR trovato")
        }
        return parsed
    }

    /// 32 lowercase hex digits, dashes of a Jellyfin GUID removed. nil if it isn't an id.
    static func normalizedId(_ raw: String) -> String? {
        let id = raw.lowercased().replacingOccurrences(of: "-", with: "")
        guard id.utf8.count == 32, id.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else { return nil }
        return id
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    /// Finite and plausible; DR is a few dB to a few tens.
    private static func validValue(_ value: Double?) -> Double? {
        guard let value, value.isFinite, abs(value) < 1000 else { return nil }
        return value
    }

    // MARK: JSON

    private static func parseJSON(_ bytes: [UInt8]) throws -> (rows: [Row], invalid: Int) {
        var object: Any
        do {
            object = try JSONSerialization.jsonObject(with: Data(bytes))
        } catch {
            // Python writes NaN/Infinity, which isn't JSON: read them as null (an invalid row).
            var text = String(decoding: bytes, as: UTF8.self)
            for token in ["-Infinity", "Infinity", "NaN"] { text = text.replacingOccurrences(of: token, with: "null") }
            guard let fixed = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else {
                throw DRImportError.unreadable("JSON non valido")
            }
            object = fixed
        }
        guard let dictionary = object as? [String: Any] else {
            throw DRImportError.unreadable("il JSON non è un elenco id → DR")
        }

        var rows: [Row] = []
        rows.reserveCapacity(dictionary.count)
        var invalid = 0
        for (key, entry) in dictionary {
            let value: Double?
            var measured: Date?
            if let nested = entry as? [String: Any] {
                value = number(nested["value"])
                measured = date(nested["measured"])
            } else {
                value = number(entry)
            }
            guard let id = normalizedId(key), let valid = validValue(value) else {
                invalid += 1
                continue
            }
            rows.append(Row(id: id, value: valid, measured: measured))
        }
        return (rows, invalid)
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID(): return number.doubleValue
        case let text as String: return parseDecimal(text)
        default: return nil
        }
    }

    /// Swift reference-date seconds (the app's own encoding) or an ISO 8601 string.
    private static func date(_ any: Any?) -> Date? {
        switch any {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        case let text as String:
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text)
        default:
            return nil
        }
    }

    /// "20.35" and "20,35" (Italian spreadsheets).
    private static func parseDecimal(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }

    // MARK: CSV

    private static func parseCSV(_ bytes: [UInt8]) throws -> (rows: [Row], invalid: Int) {
        // Excel in Italian writes semicolons: the header line tells.
        let headerEnd = bytes.firstIndex(of: 10) ?? bytes.count
        let header = bytes[..<headerEnd]
        let delimiter: UInt8 = !header.contains(UInt8(ascii: ",")) && header.contains(UInt8(ascii: ";")) ? UInt8(ascii: ";") : UInt8(ascii: ",")

        var records = csvRecords(bytes, delimiter: delimiter)
        guard !records.isEmpty else { throw DRImportError.unreadable("il file è vuoto") }
        let columns = records.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let idColumn = columns.firstIndex(of: "id"),
              let exactColumn = columns.firstIndex(of: "dr esatto") ?? columns.firstIndex(of: "dr") else {
            throw DRImportError.unreadable("servono le colonne «id» e «DR esatto» (o «DR»)")
        }
        // The integer DR is the fallback for a row whose exact value is empty.
        let roundColumn = columns.firstIndex(of: "dr esatto") != nil ? columns.firstIndex(of: "dr") : nil

        var rows: [Row] = []
        rows.reserveCapacity(records.count)
        var invalid = 0
        for record in records {
            // Blank lines and a trailing newline aren't rows.
            if record.count == 1 && record[0].trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let value = validValue(record.indices.contains(exactColumn) ? parseDecimal(record[exactColumn]) : nil)
                ?? validValue(roundColumn.flatMap { record.indices.contains($0) ? parseDecimal(record[$0]) : nil })
            guard record.indices.contains(idColumn), let id = normalizedId(record[idColumn].trimmingCharacters(in: .whitespaces)),
                  let value else {
                invalid += 1
                continue
            }
            rows.append(Row(id: id, value: value, measured: nil))
        }
        return (rows, invalid)
    }

    /// RFC 4180: quoted fields can hold delimiters, line breaks and doubled quotes.
    private static func csvRecords(_ bytes: [UInt8], delimiter: UInt8) -> [[String]] {
        let quote = UInt8(ascii: "\"")
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var i = 0
        func endField() {
            record.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }
        while i < bytes.count {
            let byte = bytes[i]
            if inQuotes {
                if byte == quote {
                    if i + 1 < bytes.count, bytes[i + 1] == quote {
                        field.append(quote)
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == quote {
                inQuotes = true
            } else if byte == delimiter {
                endField()
            } else if byte == 10 || byte == 13 {
                if byte == 13, i + 1 < bytes.count, bytes[i + 1] == 10 { i += 1 }  // CRLF
                endField()
                records.append(record)
                record = []
            } else {
                field.append(byte)
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty {
            endField()
            records.append(record)
        }
        return records
    }
}
