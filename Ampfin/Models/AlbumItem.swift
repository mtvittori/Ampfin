import Foundation

struct AlbumItem: Codable, Identifiable, Hashable {
    let Id: String
    var id: String { Id }
    let Name: String
    let AlbumArtist: String?
    let ProductionYear: Int?
    let Genres: [String]?

    // Jellyfin returns DateAdded as ISO8601 string. Keep raw string and expose a parsed Date.
    let DateAdded: String?
    var dateAddedDate: Date? {
        guard let DateAdded = DateAdded else { return nil }
        // Use ISO8601DateFormatter which is what Jellyfin normally returns
        let formatter = ISO8601DateFormatter()
        // Ensure fractional seconds are supported
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: DateAdded) { return date }
        // Try without fractional seconds as a fallback
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: DateAdded)
    }

    // Necessario per usare AlbumItem con NavigationLink(value: ...)
    func hash(into hasher: inout Hasher) {
        hasher.combine(Id)
    }
    static func == (lhs: AlbumItem, rhs: AlbumItem) -> Bool {
        lhs.Id == rhs.Id
    }
}
