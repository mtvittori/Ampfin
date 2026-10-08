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

    /// Sorting 1.000 albums by this parses each date many times: the formatter is shared,
    /// and the fraction (Jellyfin sends 7 digits) is dropped, as the formatter wants 3 or none.
    var dateAddedDate: Date? {
        guard let raw = DateCreated ?? DateAdded else { return nil }
        return Self.parseDate(raw)
    }

    private static func parseDate(_ raw: String) -> Date? {
        var text = raw
        if let dot = text.firstIndex(of: ".") {
            let rest = text[dot...].drop(while: { $0 == "." || $0.isNumber })
            text = String(text[..<dot]) + rest
        }
        if !text.hasSuffix("Z"), !text.contains("+") { text += "Z" }
        return dateParser.date(from: text)
    }
    private static let dateParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // Necessario per usare AlbumItem con NavigationLink(value: ...)
    func hash(into hasher: inout Hasher) {
        hasher.combine(Id)
    }
    static func == (lhs: AlbumItem, rhs: AlbumItem) -> Bool {
        lhs.Id == rhs.Id
    }
}
