import Foundation

struct AlbumItem: Codable, Identifiable, Hashable {
    let Id: String
    var id: String { Id }
    let Name: String
    let AlbumArtist: String?
    let ProductionYear: Int?
    let Genres: [String]?

    // Old name, never sent by Jellyfin: kept so library caches written before still decode.
    let DateAdded: String?
    /// When the album was added to the library ("DateCreated" in Jellyfin; needs
    /// `Fields=DateCreated` in the request).
    var DateCreated: String?
    /// Release date ("PremiereDate"). Jellyfin stores the release day as UTC midnight of the
    /// local day, so it must be read as an instant and compared in the device's time zone.
    var PremiereDate: String?
    var premiereDateValue: Date? { PremiereDate.flatMap(Self.parseDate) }

    /// Parsed on every call (no stored copy, so the Codable shape stays); cheap enough to
    /// call per row, but sorts should still read each date once (see `JellyfinDate`).
    var dateAddedDate: Date? {
        guard let raw = DateCreated ?? DateAdded else { return nil }
        return Self.parseDate(raw)
    }

    static func parseDate(_ raw: String) -> Date? {
        JellyfinDate.parse(raw)
    }

    // Necessario per usare AlbumItem con NavigationLink(value: ...)
    func hash(into hasher: inout Hasher) {
        hasher.combine(Id)
    }
    static func == (lhs: AlbumItem, rhs: AlbumItem) -> Bool {
        lhs.Id == rhs.Id
    }
}
