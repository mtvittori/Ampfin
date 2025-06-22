import Foundation

// Anche se usiamo solo i nomi dei generi, avere il modello completo è una buona pratica
struct GenreItem: Codable, Identifiable {
    let Id: String
    var id: String { Id }
    let Name: String
}
