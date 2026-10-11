import Foundation
import Testing
@testable import Ampfin

@MainActor
struct DRImportTests {
    private let idA = "9872a7f84ccdf9b0a2b4c4a4cf655695"
    private let idB = "0f0e437d9178cb702c5f8b8b7c59998c"
    private let idC = "effd4bbc65fc5498206c7bdfe3d0cacc"

    /// A store that saves to a temporary file, never to the user's results.
    private func makeStore() -> DRStore {
        DRStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("dr-test-\(UUID().uuidString).json"))
    }

    @Test func plainJSON() throws {
        let store = makeStore()
        let json = #"{"\#(idA)": 20.35, "\#(idB)": 19}"#
        let result = try store.importData(Data(json.utf8), knownIds: [])
        #expect(result == DRImportResult(imported: 2, unchanged: 0, skipped: 0))
        #expect(store.results[idA]?.value == 20.35)
        #expect(store.results[idB]?.dr == 19)
    }

    @Test func ampfinExportRoundTrips() throws {
        let source = makeStore()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        source.recordMany([idA: DRResult(value: 12.34, measured: date), idB: DRResult(value: 7.5, measured: date)])

        let target = makeStore()
        let result = try target.importData(try source.exportData(), knownIds: [idA, idB])
        #expect(result.imported == 2)
        #expect(target.results[idA]?.value == 12.34)
        #expect(target.results[idA]?.measured == date)

        // Same file again: nothing changes.
        #expect(try target.importData(try source.exportData(), knownIds: []) == DRImportResult(imported: 0, unchanged: 2, skipped: 0))
    }

    @Test func exportMeasuredAsReferenceSecondsOrISO() throws {
        let store = makeStore()
        let json = #"{"\#(idA)": {"value": 10.5, "measured": 1000}, "\#(idB)": {"value": 9, "measured": "2026-01-02T03:04:05Z"}, "\#(idC)": {"value": 8}}"#
        _ = try store.importData(Data(json.utf8), knownIds: [])
        #expect(store.results[idA]?.measured == Date(timeIntervalSinceReferenceDate: 1000))
        #expect(store.results[idB]?.measured == ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z"))
        #expect(abs(store.results[idC]!.measured.timeIntervalSinceNow) < 5)
    }

    @Test func csvWithQuotedCommasAndExactColumn() throws {
        let store = makeStore()
        let csv = """
        posizione,DR,DR esatto,artista,album,titolo,percorso,id
        1,20,20.35,Penfold,"Maxwell's in Hoboken, NJ 09.17.11","06-Fate, ""Confidence"" And An Encounter","/mnt/a, b/c.mp3",\(idA)
        2,19,18.6,X,Y,Z,/p.mp3,\(idB)\r
        """
        let result = try store.importData(Data(csv.utf8), knownIds: [])
        #expect(result == DRImportResult(imported: 2, unchanged: 0, skipped: 0))
        #expect(store.results[idA]?.value == 20.35)
        #expect(store.results[idB]?.value == 18.6)
    }

    @Test func csvWithOnlyIntegerDR() throws {
        let store = makeStore()
        let result = try store.importData(Data("id,DR\n\(idA),14\n".utf8), knownIds: [])
        #expect(result.imported == 1)
        #expect(store.results[idA]?.value == 14)
    }

    @Test func guidWithDashesIsNormalised() throws {
        let store = makeStore()
        let dashed = "9872a7f8-4ccd-f9b0-a2b4-c4a4cf655695".uppercased()
        let result = try store.importData(Data(#"{"\#(dashed)": 11}"#.utf8), knownIds: [dashed.lowercased()])
        #expect(result.imported == 1)
        #expect(store.results[idA]?.value == 11)
    }

    @Test func unknownIdsAndBadValuesAreSkipped() throws {
        let store = makeStore()
        let json = #"{"\#(idA)": 12, "\#(idB)": 13, "\#(idC)": "NaN", "not-an-id": 5}"#
        let result = try store.importData(Data(json.utf8), knownIds: [idA, idC])
        // idB is not in the library, idC is NaN, "not-an-id" is not an id.
        #expect(result == DRImportResult(imported: 1, unchanged: 0, skipped: 3))
        #expect(store.results.keys.sorted() == [idA])
    }

    @Test func bareNaNInCSVAndJSONIsSkipped() throws {
        let store = makeStore()
        let csv = try store.importData(Data("id,DR esatto\n\(idA),nan\n\(idB),12\n".utf8), knownIds: [])
        #expect(csv == DRImportResult(imported: 1, unchanged: 0, skipped: 1))
        let json = try store.importData(Data(#"{"\#(idC)": NaN}"#.utf8), knownIds: [])
        #expect(json == DRImportResult(imported: 0, unchanged: 0, skipped: 1))
    }

    @Test func sameValueAtHundredthsIsUnchanged() throws {
        let store = makeStore()
        store.recordMany([idA: DRResult(value: 12.341, measured: Date(timeIntervalSince1970: 0))])
        let result = try store.importData(Data(#"{"\#(idA)": 12.34, "\#(idB)": 5}"#.utf8), knownIds: [])
        #expect(result == DRImportResult(imported: 1, unchanged: 1, skipped: 0))
        // The unchanged song keeps its original date.
        #expect(store.results[idA]?.measured == Date(timeIntervalSince1970: 0))
    }

    @Test func importedValueReplacesExisting() throws {
        let store = makeStore()
        store.recordMany([idA: DRResult(value: 5, measured: Date(timeIntervalSince1970: 0))])
        _ = try store.importData(Data(#"{"\#(idA)": 9}"#.utf8), knownIds: [])
        #expect(store.results[idA]?.value == 9)
    }

    @Test func garbageThrows() {
        let store = makeStore()
        #expect(throws: DRImportError.self) { try store.importData(Data(), knownIds: []) }
        #expect(throws: DRImportError.self) { try store.importData(Data("hello,world\n1,2\n".utf8), knownIds: []) }
        #expect(throws: DRImportError.self) { try store.importData(Data("{broken".utf8), knownIds: []) }
        #expect(throws: DRImportError.self) { try store.importData(Data("[1,2]".utf8), knownIds: []) }
    }

    // MARK: Real files from the server script (skipped when not on this machine)

    @Test func realJSONFile() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/dr-meter/dr-ampfin.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let start = Date()
        let parsed = try DRImportParser.parse(data)
        print("dr-ampfin.json: \(parsed.rows.count) rows, \(parsed.invalid) invalid, \(Date().timeIntervalSince(start)) s")
        #expect(parsed.rows.count == 9293)
        #expect(parsed.invalid == 0)

        let store = makeStore()
        let importStart = Date()
        let result = try store.importData(data, knownIds: [])
        print("import into store: \(Date().timeIntervalSince(importStart)) s")
        #expect(result.imported == 9293)
    }

    @Test func realCSVFile() throws {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/dr-meter/dr-classifica.csv")
        guard let data = try? Data(contentsOf: url) else { return }
        let start = Date()
        let parsed = try DRImportParser.parse(data)
        print("dr-classifica.csv: \(parsed.rows.count) rows, \(parsed.invalid) invalid, \(Date().timeIntervalSince(start)) s")
        #expect(parsed.rows.count == 9293)
        #expect(parsed.invalid == 0)
    }
}
