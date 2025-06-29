import Foundation

// Aggiunto Hashable per poterlo usare nei NavigationLink(value: ...)
struct ArtistItem: Codable, Identifiable, Hashable {
    let Id: String
    var id: String { Id }
    let Name: String
    let Genres: [String]?
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(Id)
    }
    
    static func == (lhs: ArtistItem, rhs: ArtistItem) -> Bool {
        lhs.Id == rhs.Id
    }
}
