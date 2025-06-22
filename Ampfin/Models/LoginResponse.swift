import Foundation

// Modello per la risposta di autenticazione
struct LoginResponse: Codable {
    let AccessToken: String
    let User: JellyfinUser
}

struct JellyfinUser: Codable {
    let Id: String
    let Name: String?
}
