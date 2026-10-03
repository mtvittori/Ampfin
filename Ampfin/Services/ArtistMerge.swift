// ArtistMerge.swift
// Folds the server's artist list into one entry per real artist. Jellyfin often has
// the same artist several times (nine "Beyoncé", "Florence + The Machine" and
// "Florence + the Machine") and combined credits as artists of their own
// ("David Guetta feat. Sia", "Beyoncé, Miley Cyrus"). The rules here are applied on
// top of the server data: nothing on the server changes.

import Foundation
import Combine

/// The merge settings: two automatic rules and the merges made by hand.
final class ArtistMergeStore: ObservableObject {
    static let shared = ArtistMergeStore()

    static let autoMergeKey = "artistMerge_duplicates"
    static let splitCreditsKey = "artistMerge_splitCredits"
    static let manualMergesKey = "artistMerge_manual"

    /// Same name apart from case, accents or a trailing "(…)": one artist.
    @Published var autoMergeDuplicates: Bool {
        didSet { UserDefaults.standard.set(autoMergeDuplicates, forKey: Self.autoMergeKey) }
    }

    /// "A feat. B", "A, B": the albums go under A and B, and the combined entry disappears.
    @Published var splitCredits: Bool {
        didSet { UserDefaults.standard.set(splitCredits, forKey: Self.splitCreditsKey) }
    }

    /// Merges made by hand: key of the merged artist → key of the artist it joins.
    @Published private(set) var manualMerges: [String: String] {
        didSet { UserDefaults.standard.set(manualMerges, forKey: Self.manualMergesKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        autoMergeDuplicates = defaults.object(forKey: Self.autoMergeKey) as? Bool ?? true
        splitCredits = defaults.object(forKey: Self.splitCreditsKey) as? Bool ?? true
        manualMerges = defaults.dictionary(forKey: Self.manualMergesKey) as? [String: String] ?? [:]
    }

    /// Reads everything again, after a backup has been restored.
    func reload() {
        let fresh = ArtistMergeStore()
        autoMergeDuplicates = fresh.autoMergeDuplicates
        splitCredits = fresh.splitCredits
        manualMerges = fresh.manualMerges
    }

    /// Puts every name of `others` under `main`.
    func merge(_ others: [ArtistItem], into main: ArtistItem) {
        let root = resolve(Self.key(main.Name))
        var updated = manualMerges
        for artist in others {
            for name in artist.mergedNames ?? [artist.Name] {
                let key = Self.key(name)
                if key != root { updated[key] = root }
            }
        }
        manualMerges = updated
    }

    /// Undoes the manual merges of the artists behind `names`.
    func separate(_ names: [String]) {
        var updated = manualMerges
        for name in names {
            let key = Self.key(name)
            updated.removeValue(forKey: key)
            // Artists that had been merged into this one come back on their own too.
            for (other, target) in updated where target == key {
                updated.removeValue(forKey: other)
            }
        }
        manualMerges = updated
    }

    /// Undoes a whole manual group: every artist merged, directly or not, into `root`.
    func separateGroup(root: String) {
        manualMerges = manualMerges.filter { resolve($0.key) != root }
    }

    /// Manual groups: the main artist's key and the keys merged into it.
    var manualGroups: [(root: String, members: [String])] {
        Dictionary(grouping: manualMerges.keys, by: resolve)
            .map { (root: $0.key, members: $0.value.sorted()) }
            .sorted { $0.root < $1.root }
    }

    /// Follows the chain of manual merges to the artist at the end.
    func resolve(_ key: String) -> String {
        var current = key
        var seen: Set<String> = [key]
        while let next = manualMerges[current], seen.insert(next).inserted {
            current = next
        }
        return current
    }

    /// Whether `key` takes part in a manual merge, on either side.
    func isManual(_ key: String) -> Bool {
        manualMerges[key] != nil || manualMerges.values.contains(key)
    }

    /// Keys already worked out: `key` runs for every name on every lookup.
    private static let keyCache = NSCache<NSString, NSString>()

    /// Comparison key: case, accents, spaces and a trailing "(…)" or "[…]" don't count.
    static func key(_ name: String) -> String {
        if let cached = keyCache.object(forKey: name as NSString) { return cached as String }
        let key = computeKey(name)
        keyCache.setObject(key as NSString, forKey: name as NSString)
        return key
    }

    private static func computeKey(_ name: String) -> String {
        var key = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        key = key.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, with: "", options: .regularExpression)
        key = key.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        key = key.trimmingCharacters(in: .whitespaces)
        // Library-style "Neighbourhood, The" is "The Neighbourhood".
        if key.hasSuffix(", the") {
            key = "the " + key.dropLast(5)
        }
        return key.isEmpty ? name : key
    }

    /// The artists inside a combined credit, or [] when it isn't one. "feat.", commas,
    /// semicolons and " / " always split; "&", " x " and " and " only when the first
    /// half is a known artist and the rest isn't a band suffix like "& The Six"
    /// ("David Guetta & Afrojack" yes, "Daisy Jones & The Six" and "Simon & Garfunkel" no).
    static func creditParts(_ name: String, isKnown: (String) -> Bool) -> [String] {
        let strong = #"\s*(?:,|;|\s/\s|\s(?:feat\.?|ft\.?|featuring|with)\s)\s*"#
        var parts = split(name, by: strong)
        parts = parts.flatMap { part -> [String] in
            let pieces = split(part, by: #"\s+(?:&|x|and|e)\s+"#)
            let bandSuffix = pieces.dropFirst().contains { $0.lowercased().hasPrefix("the ") }
            if pieces.count > 1, isKnown(pieces[0]), !bandSuffix { return pieces }
            return [part]
        }
        return parts.count > 1 ? parts : []
    }

    /// Compiled once: compiling a regular expression per call was a large share of the work.
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    private static func split(_ text: String, by pattern: String) -> [String] {
        let regex: NSRegularExpression
        if let cached = regexCache.object(forKey: pattern as NSString) {
            regex = cached
        } else if let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            regexCache.setObject(compiled, forKey: pattern as NSString)
            regex = compiled
        } else {
            return [text]
        }
        let ns = text as NSString
        var pieces: [String] = []
        var start = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            start = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: start))
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// The artist list after the rules, with lookups by name.
struct ArtistIndex {
    private(set) var artists: [ArtistItem] = []
    private var byName: [String: ArtistItem] = [:]
    private var byKey: [String: ArtistItem] = [:]

    static let empty = ArtistIndex()

    /// The artist a name belongs to: exact name first, then the comparison key.
    func artist(named name: String) -> ArtistItem? {
        byName[name] ?? byKey[ArtistMergeStore.key(name)]
    }

    init() {}

    init(raw: [ArtistItem], rules: ArtistMergeStore) {
        // 1. Group: by key when merging duplicates, by exact name otherwise;
        //    manual merges always group by the artist at the end of the chain.
        func group(of name: String) -> String {
            let key = ArtistMergeStore.key(name)
            if rules.isManual(key) { return rules.resolve(key) }
            return rules.autoMergeDuplicates ? key : "=" + name
        }

        var order: [String] = []
        var members: [String: [ArtistItem]] = [:]
        for artist in raw {
            let g = group(of: artist.Name)
            if members[g] == nil { order.append(g) }
            members[g, default: []].append(artist)
        }

        // 2. Combined credits whose first artist exists on its own are dropped:
        //    their albums show up under each artist they name.
        let knownKeys = Set(raw.map { ArtistMergeStore.key($0.Name) })
        if rules.splitCredits {
            for g in order {
                guard let group = members[g], group.count == 1, let only = group.first,
                      !rules.isManual(ArtistMergeStore.key(only.Name)) else { continue }
                let parts = ArtistMergeStore.creditParts(only.Name) { knownKeys.contains(ArtistMergeStore.key($0)) }
                if let first = parts.first, knownKeys.contains(ArtistMergeStore.key(first)) {
                    members[g] = nil
                }
            }
        }

        // 3. One entry per group: the photo from the member that has the best one,
        //    the name everybody agrees on, genres pooled.
        for g in order {
            guard let group = members[g], let first = group.first else { continue }
            if group.count == 1 {
                artists.append(first)
                continue
            }
            let photo = group.first { !($0.BackdropImageTags ?? []).isEmpty }
                ?? group.first { $0.ImageTags?["Primary"] != nil }
                ?? first
            // A manual merge is named after the artist chosen as main; otherwise the most
            // common spelling wins, the shorter one on a tie.
            let rootName = rules.isManual(g) ? group.first { ArtistMergeStore.key($0.Name) == g }?.Name : nil
            let counts = Dictionary(group.map { ($0.Name, 1) }, uniquingKeysWith: +)
            let name = rootName ?? counts.max { a, b in
                a.value != b.value ? a.value < b.value : a.key.count > b.key.count
            }?.key ?? first.Name
            var genres: [String] = []
            for genre in group.flatMap({ $0.Genres ?? [] }) where !genres.contains(genre) {
                genres.append(genre)
            }
            artists.append(ArtistItem(Id: photo.Id, Name: name, Genres: genres.isEmpty ? nil : genres,
                                      ImageTags: photo.ImageTags, BackdropImageTags: photo.BackdropImageTags,
                                      mergedNames: Array(Set(group.map(\.Name)))))
        }

        for artist in artists {
            for name in artist.mergedNames ?? [artist.Name] {
                byName[name] = artist
                byKey[ArtistMergeStore.key(name)] = byKey[ArtistMergeStore.key(name)] ?? artist
            }
        }
    }
}
