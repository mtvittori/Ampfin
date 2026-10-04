#if os(macOS) && DEBUG
import AppKit

/// Test-only: `-provaFoto <file.png> [-provaFotoDopo <seconds>]` saves the window to a PNG
/// and quits, so the Mac layout can be looked at without screen-recording permission.
enum WindowSnapshot {
    static func scheduleIfRequested() {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: "provaFoto") else { return }
        let delay = defaults.object(forKey: "provaFotoDopo") == nil ? 8 : defaults.double(forKey: "provaFotoDopo")
        // A wide window, like the one a person would use (saved frames would shrink it).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            NSApp.windows.first(where: { $0.isVisible })?.setContentSize(NSSize(width: 1440, height: 900))
        }
        // `-provaImpostazioni YES` opens the Settings window and photographs that one.
        let settings = defaults.bool(forKey: "provaImpostazioni")
        if settings {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NSApp.activate(ignoringOtherApps: true)
                let appMenu = NSApp.mainMenu?.items.first?.submenu
                if let item = appMenu?.items.first(where: { $0.keyEquivalent == "," }) {
                    _ = appMenu?.performActionForItem(at: appMenu?.index(of: item) ?? 0)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if let view = (settings ? NSApp.windows.last(where: { $0.isVisible }) : NSApp.windows.first(where: { $0.isVisible }))?.contentView?.superview,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}
#endif
