import Foundation

struct AlbumItem: Codable, Identifiable, Hashable {
    let Id: String
    var id: String { Id }
    let Name: String
    let AlbumArtist: String?
    let ProductionYear: Int?
    let Genres: [String]?

    // Necessario per usare AlbumItem con NavigationLink(value: ...)
    func hash(into hasher: inout Hasher) {
        hasher.combine(Id)
    }
    static func == (lhs: AlbumItem, rhs: AlbumItem) -> Bool {
        lhs.Id == rhs.Id
    }
}
