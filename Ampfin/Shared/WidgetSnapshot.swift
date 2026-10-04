// WidgetSnapshot.swift — compiled into the app AND the widget extension.
// What the widgets show, written by the app into the shared App Group: the song
// playing (with its cover's color, as on the album pages), what comes next, the
// recently played and the favorite albums. Covers are saved there already small:
// widgets don't download images themselves (lesson from the Plancia app).

import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct WidgetSnapshot: Codable, Equatable {
    struct Track: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let albumId: String
    }

    struct Album: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let artist: String
    }

    /// RGB of the cover's bottom edge and whether text on it should be dark.
    struct Palette: Codable, Equatable {
        let red: Double, green: Double, blue: Double
        let isLight: Bool

        var background: Color { Color(red: red, green: green, blue: blue) }
        var foreground: Color { isLight ? .black : .white }
        var secondary: Color { foreground.opacity(0.65) }

        static let neutral = Palette(red: 0.16, green: 0.16, blue: 0.18, isLight: false)
    }

    var nowPlaying: Track?
    var isPlaying = false
    var palette: Palette = .neutral
    var upNext: [Track] = []
    var recentAlbums: [Album] = []
    var favoriteAlbums: [Album] = []
    var updated = Date()

    static let placeholder = WidgetSnapshot(
        nowPlaying: Track(id: "-", title: "Brianstorm", artist: "Arctic Monkeys", album: "Favourite Worst Nightmare", albumId: "-"),
        isPlaying: true,
        palette: Palette(red: 0.22, green: 0.24, blue: 0.27, isLight: false),
        upNext: [Track(id: "a", title: "Teddy Picker", artist: "Arctic Monkeys", album: "", albumId: "-"),
                 Track(id: "b", title: "D Is for Dangerous", artist: "Arctic Monkeys", album: "", albumId: "-")],
        recentAlbums: (0..<6).map { Album(id: "\($0)", title: "Album", artist: "Artista") },
        favoriteAlbums: (0..<6).map { Album(id: "\($0)", title: "Album", artist: "Artista") }
    )
}

/// The App Group files: snapshot.json and the covers, by item id.
enum WidgetStore {
    static let appGroupId = "group.com.ampfin.shared"

    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    private static var snapshotURL: URL? { container?.appendingPathComponent("widget-snapshot.json") }
    static var artDirectory: URL? { container?.appendingPathComponent("WidgetArt", isDirectory: true) }

    static func load() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let url = snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func artURL(for itemId: String) -> URL? {
        artDirectory?.appendingPathComponent("\(itemId).jpg")
    }

    /// The saved cover as a SwiftUI image, or nil.
    static func image(for itemId: String) -> Image? {
        guard let url = artURL(for: itemId), let data = try? Data(contentsOf: url) else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}

/// Widget kinds, for targeted reloads.
enum WidgetKinds {
    static let nowPlaying = "AmpfinNowPlaying"
    static let recent = "AmpfinRecent"
    static let favorites = "AmpfinFavorites"
}
