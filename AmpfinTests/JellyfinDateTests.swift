import Foundation
import Testing
@testable import Ampfin

struct JellyfinDateTests {
    /// What the app read before the fast parser: the formatter, after cutting the fraction.
    private func reference(_ text: String) -> Date? {
        JellyfinDate.parseSlow(text)
    }

    @Test func readsJellyfinTimestamps() {
        // 2026-10-09T14:03:21Z
        let expected = Date(timeIntervalSince1970: 1_791_554_601)
        #expect(JellyfinDate.parse("2026-10-09T14:03:21Z") == expected)
        #expect(JellyfinDate.parse("2026-10-09T14:03:21.1234567Z") == expected)
        #expect(JellyfinDate.parse("2026-10-09T14:03:21") == expected)
        #expect(JellyfinDate.parse("1970-01-01T00:00:00.0000000Z") == Date(timeIntervalSince1970: 0))
        #expect(JellyfinDate.parse("1969-12-31T23:59:59Z") == Date(timeIntervalSince1970: -1))
    }

    @Test func appliesOffsets() {
        let utc = JellyfinDate.parse("2026-10-09T12:00:00Z")
        #expect(JellyfinDate.parse("2026-10-09T14:00:00+02:00") == utc)
        #expect(JellyfinDate.parse("2026-10-09T07:00:00-05:00") == utc)
    }

    @Test func handlesLeapDays() {
        #expect(JellyfinDate.parse("2024-02-29T00:00:00Z") == Date(timeIntervalSince1970: 1_709_164_800))
        // No 29 February in 2023, and no 13th month: not dates.
        #expect(JellyfinDate.parse("2023-02-29T00:00:00Z") == reference("2023-02-29T00:00:00Z"))
        #expect(JellyfinDate.parse("2024-13-01T00:00:00Z") == nil)
    }

    @Test func rejectsGarbage() {
        #expect(JellyfinDate.parse("") == nil)
        #expect(JellyfinDate.parse("garbage") == nil)
        #expect(JellyfinDate.parse("2026-10-09") == reference("2026-10-09"))
    }

    @Test func fastParserAgreesWithTheFormatter() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%07dZ",
                              Int.random(in: 1971...2060, using: &generator), Int.random(in: 1...12, using: &generator),
                              Int.random(in: 1...28, using: &generator), Int.random(in: 0...23, using: &generator),
                              Int.random(in: 0...59, using: &generator), Int.random(in: 0...59, using: &generator),
                              Int.random(in: 0...9_999_999, using: &generator))
            #expect(JellyfinDate.parse(text) == reference(text), "\(text)")
        }
    }

    @Test func sortsNewestFirstAndKeepsTies() {
        let items = [("a", "2026-01-01T00:00:00Z"), ("b", "2026-03-01T00:00:00Z"),
                     ("c", nil), ("d", "2026-03-01T00:00:00.5Z"), ("e", "2026-03-01T00:00:00Z")] as [(String, String?)]
        let sorted = items.sortedNewestFirst { $0.1.flatMap(JellyfinDate.parse) }.map(\.0)
        // The fraction is dropped, so b, d and e tie and stay in order; the undated one is last.
        #expect(sorted == ["b", "d", "e", "a", "c"])
    }
}
