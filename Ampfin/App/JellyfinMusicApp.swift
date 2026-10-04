#if os(macOS)
import SwiftUI
import Cocoa

@main
struct JellyfinMusicApp: App {
    @StateObject private var viewModel = JellyfinViewModel()
    @ObservedObject private var colorManager = AccentColorManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .tint(colorManager.effectiveTint)
                .onAppear { appDelegate.viewModel = viewModel }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)

        // ⌘, as in every Mac app.
        Settings {
            NavigationStack {
                SettingsView()
            }
            .environmentObject(viewModel)
            .tint(colorManager.effectiveTint)
            .frame(width: 600, height: 700)
        }
    }
}
#else
import SwiftUI
import UIKit
import CarPlay

class AmpfinAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role.rawValue == "CPTemplateApplicationSceneSessionRoleApplication" {
            let config = UISceneConfiguration(name: "AmpfinCarPlayConfiguration", sessionRole: connectingSceneSession.role)
            config.delegateClass = CarPlaySceneDelegate.self
            return config
        }
        let config = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        return config
    }
}

@main
struct JellyfinMusicApp: App {
    @UIApplicationDelegateAdaptor(AmpfinAppDelegate.self) var appDelegate
    @StateObject private var viewModel = JellyfinViewModel()
    @ObservedObject private var colorManager = AccentColorManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .tint(colorManager.effectiveTint)
        }
    }
}
#endif
