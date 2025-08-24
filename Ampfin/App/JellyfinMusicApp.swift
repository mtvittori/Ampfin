// In Ampfin/App/JellyfinMusicApp.swift

import SwiftUI
import Cocoa

@main
struct JellyfinMusicApp: App {
    @StateObject private var viewModel = JellyfinViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear { appDelegate.viewModel = viewModel }
        }
    }
}
