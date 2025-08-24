import Cocoa
import SwiftUI
import Combine

/// AppDelegate manages Dock menu and playback control integration
class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// Call this from anywhere to refresh the Dock menu.
    static func refreshDockMenu() {
        NSApp.dockTile.display()
    }
    
    // Provide a way to get the shared ViewModel or player manager
    weak var viewModel: JellyfinViewModel?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewModel?.$isPlaying.sink { _ in
            AppDelegate.refreshDockMenu()
        }.store(in: &cancellables)
    }
    
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        
        // Play/Pause
        let playPauseTitle: String
        if let isPlaying = viewModel?.isPlaying, isPlaying {
            playPauseTitle = "Pause"
        } else {
            playPauseTitle = "Play"
        }
        menu.addItem(withTitle: playPauseTitle, action: #selector(togglePlayPause), keyEquivalent: "")
        
        // Next
        menu.addItem(withTitle: "Next", action: #selector(nextTrack), keyEquivalent: "")
        
        // Previous
        menu.addItem(withTitle: "Previous", action: #selector(previousTrack), keyEquivalent: "")
        
        // Repeat
        let repeatTitle: String
        switch viewModel?.repeatMode {
        case .one: repeatTitle = "Repeat: One"
        case .all: repeatTitle = "Repeat: All"
        case .off: repeatTitle = "Repeat: Off"
        default: repeatTitle = "Repeat"
        }
        menu.addItem(withTitle: repeatTitle, action: #selector(toggleRepeatMode), keyEquivalent: "")
        
        return menu
    }
    
    @objc func togglePlayPause() {
        DispatchQueue.main.async {
            if let viewModel = self.viewModel {
                if viewModel.isPlaying {
                    viewModel.playerManager.pause()
                } else {
                    viewModel.playerManager.play()
                }
            }
        }
    }
    
    @objc func nextTrack() {
        DispatchQueue.main.async {
            self.viewModel?.playerManager.forward()
        }
    }
    
    @objc func previousTrack() {
        DispatchQueue.main.async {
            self.viewModel?.playerManager.backward()
        }
    }
    
    @objc func toggleRepeatMode() {
        DispatchQueue.main.async {
            self.viewModel?.toggleRepeatMode()
        }
    }
}
