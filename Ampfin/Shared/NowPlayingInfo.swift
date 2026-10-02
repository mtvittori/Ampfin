import Foundation

/// Shared data structure for communicating now-playing state between the main app and the widget.
/// Both the app target and the widget extension target should include this file.
struct NowPlayingInfo: Codable {
    let trackName: String
    let artistName: String
    let albumName: String
    let albumId: String
    let trackId: String
    let isPlaying: Bool
    let serverUrl: String
    let token: String
    let userId: String
    
    /// The artwork URL constructed from server info
    var artworkURLString: String {
        guard !serverUrl.isEmpty, !albumId.isEmpty else { return "" }
        return "\(serverUrl)/Items/\(albumId)/Images/Primary?maxWidth=300&maxHeight=300"
    }
}

/// Keys and helpers for shared UserDefaults (App Group)
enum SharedDefaults {
    /// App Group identifier — must match the App Group configured in both targets' entitlements
    static let appGroupId = "group.com.ampfin.shared"
    
    static let nowPlayingKey = "nowPlayingInfo"
    
    static var suite: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }
    
    static func saveNowPlaying(_ info: NowPlayingInfo?) {
        guard let defaults = suite else {
            print("[Widget Sync] ERROR: Could not create UserDefaults suite for '\(appGroupId)'")
            return
        }
        if let info {
            if let data = try? JSONEncoder().encode(info) {
                defaults.set(data, forKey: nowPlayingKey)
                defaults.synchronize()
                print("[Widget Sync] Saved: \(info.trackName) - \(info.artistName) (playing: \(info.isPlaying))")
            }
        } else {
            defaults.removeObject(forKey: nowPlayingKey)
            defaults.synchronize()
            print("[Widget Sync] Cleared now playing data")
        }
    }
    
    static func loadNowPlaying() -> NowPlayingInfo? {
        guard let defaults = suite else {
            print("[Widget Sync] ERROR: Could not create UserDefaults suite for '\(appGroupId)'")
            return nil
        }
        guard let data = defaults.data(forKey: nowPlayingKey) else {
            print("[Widget Sync] No data found for key '\(nowPlayingKey)'")
            return nil
        }
        let info = try? JSONDecoder().decode(NowPlayingInfo.self, from: data)
        if let info {
            print("[Widget Sync] Loaded: \(info.trackName) - \(info.artistName)")
        }
        return info
    }
}
