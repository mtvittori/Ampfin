import Foundation
import Testing
@testable import Ampfin

struct SongCacheEvictionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private let mb: Int64 = 1024 * 1024

    private func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * day) }

    private func entry(_ key: String, mb size: Int64 = 10, added: Double, plays: [Double] = []) -> SongCacheEntry {
        SongCacheEntry(key: key, size: size * mb, added: ago(added), plays: plays.map(ago))
    }

    private func policy(limitMB: Int64 = 10_000, days: Int = 30, minPlays: Int = 2) -> SongCachePolicy {
        SongCachePolicy(limitBytes: limitMB * mb, windowDays: days, minPlays: minPlays)
    }

    private func remove(_ entries: [SongCacheEntry], protected: Set<String> = [], _ policy: SongCachePolicy) -> Set<String> {
        Set(SongCacheEviction.keysToRemove(entries: entries, protected: protected, now: now, policy: policy))
    }

    @Test func newFilesAreSafeUntilAFullPeriodPassed() {
        let entries = [entry("new", added: 29)]
        #expect(remove(entries, policy()).isEmpty)
    }

    @Test func oldFilesNeedEnoughPlaysInThePeriod() {
        let entries = [
            entry("unplayed", added: 40),
            entry("once", added: 40, plays: [5]),
            entry("twice", added: 40, plays: [5, 10]),
            // Plays outside the period don't count.
            entry("stale", added: 80, plays: [40, 50, 60]),
        ]
        #expect(remove(entries, policy()) == ["unplayed", "once", "stale"])
        #expect(remove(entries, policy(minPlays: 1)) == ["unplayed", "stale"])
    }

    @Test func neverPeriodKeepsEverythingUnderTheLimit() {
        let entries = [entry("old", added: 400), entry("older", added: 800)]
        #expect(remove(entries, policy(days: 0)).isEmpty)
    }

    @Test func overTheLimitFewestPlaysGoFirstThenOldest() {
        let entries = [
            entry("often", added: 10, plays: [1, 2, 3]),
            entry("seldom", added: 10, plays: [4]),
            entry("never-new", added: 2),
            entry("never-old", added: 9),
        ]
        // 40 MB with a 25 MB limit: the two unplayed (older first) must go.
        #expect(remove(entries, policy(limitMB: 25)) == ["never-old", "never-new"])
        // Down to 15 MB: "seldom" goes too, "often" stays.
        #expect(remove(entries, policy(limitMB: 15)) == ["never-old", "never-new", "seldom"])
    }

    @Test func equalPlaysGoByOldestLastPlay() {
        let entries = [
            entry("recent", added: 20, plays: [1]),
            entry("long-ago", added: 20, plays: [15]),
        ]
        #expect(remove(entries, policy(limitMB: 10)) == ["long-ago"])
    }

    @Test func protectedFilesAreNeverRemoved() {
        let entries = [
            entry("playing", added: 60),
            entry("other", added: 60, plays: [1, 2]),
        ]
        #expect(remove(entries, protected: ["playing"], policy()) == [])
        // Over the limit with only protected files left to choose from: nothing else to drop.
        #expect(remove(entries, protected: ["playing", "other"], policy(limitMB: 5)).isEmpty)
        #expect(remove(entries, protected: ["playing"], policy(limitMB: 15, days: 0)).isEmpty == false)
    }

    @Test func ageRuleFreesSpaceBeforeTheSizeRule() {
        let entries = [
            entry("expired", mb: 30, added: 50),
            entry("fresh", mb: 30, added: 1),
        ]
        // The expired one alone brings it under 40 MB: the fresh one stays.
        #expect(remove(entries, policy(limitMB: 40)) == ["expired"])
    }
}
