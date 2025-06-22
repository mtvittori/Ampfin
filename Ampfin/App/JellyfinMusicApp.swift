// In Ampfin/App/JellyfinMusicApp.swift

import SwiftUI

@main
struct JellyfinMusicApp: App {
    // Il ViewModel viene creato qui, una sola volta, e vive per tutta l'app
    @StateObject private var viewModel = JellyfinViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                // E viene iniettato nell'ambiente per essere accessibile a tutte le viste figlie
                .environmentObject(viewModel)
        }
    }
}
