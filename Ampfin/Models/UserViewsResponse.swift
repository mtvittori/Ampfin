import Foundation

// Modello per la risposta che contiene le librerie dell'utente
struct UserViewsResponse: Codable {
    let Items: [LibraryView]
}

struct LibraryView: Codable {
    let Name: String
    let Id: String
    let CollectionType: String?
}
