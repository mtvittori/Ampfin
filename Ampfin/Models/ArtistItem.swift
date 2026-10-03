import Foundation

// Aggiunto Hashable per poterlo usare nei NavigationLink(value: ...)
struct ArtistItem: Codable, Identifiable, Hashable {
    let Id: String
    var id: String { Id }
    let Name: String
    let Genres: [String]?
    // Optional so library caches written before these fields existed still decode.
    let ImageTags: [String: String]?
    let BackdropImageTags: [String]?
    /// Every server name folded into this entry by the merge rules (nil for a plain artist).
    var mergedNames: [String]? = nil
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(Id)
    }
    
    static func == (lhs: ArtistItem, rhs: ArtistItem) -> Bool {
        lhs.Id == rhs.Id
    }
}
