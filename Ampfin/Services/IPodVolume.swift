// IPodVolume.swift
// The iPod's volume: chosen once with an open panel, remembered as a security-scoped
// bookmark (the app is sandboxed), and watched for being plugged in and out.

#if os(macOS)
import AppKit
import Foundation

@MainActor
final class IPodVolume: ObservableObject {
    static let shared = IPodVolume()

    private static let bookmarkKey = "ipodVolumeBookmark"
    private static let nameKey = "ipodVolumeName"

    /// The volume's root while it is mounted and the bookmark resolves.
    @Published private(set) var url: URL?
    /// Last known name, shown also when the iPod is unplugged.
    @Published private(set) var name: String?
    @Published private(set) var isConnected = false
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var totalBytes: Int64?
    /// Why the last chosen folder was refused.
    @Published var message: String?

    private var scopedURL: URL?
    private var observers: [NSObjectProtocol] = []

    var hasVolume: Bool { name != nil }

    private init() {
        name = UserDefaults.standard.string(forKey: Self.nameKey)
        refresh()
        // Plugging the iPod in or out changes everything shown.
        let center = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
    }

    // MARK: - Choosing

    /// "Scegli iPod…": only a folder with `.rockbox` at its root is accepted.
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        panel.message = "Scegli l'iPod (la cartella con dentro .rockbox)"
        panel.prompt = "Scegli"
        guard panel.runModal() == .OK, let picked = panel.url else { return }

        guard Self.looksLikeRockbox(picked) else {
            message = "In “\(picked.lastPathComponent)” non c'è la cartella .rockbox: scegli la radice dell'iPod."
            return
        }
        guard let bookmark = try? picked.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            message = "Non riesco a ricordare questa cartella."
            return
        }
        message = nil
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        UserDefaults.standard.set(picked.lastPathComponent, forKey: Self.nameKey)
        name = picked.lastPathComponent
        refresh()
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        stopScope()
        name = nil
        url = nil
        isConnected = false
        freeBytes = nil
        totalBytes = nil
    }

    // MARK: - State

    /// Resolves the bookmark again and reads the space; cheap, so also called on a timer.
    func refresh() {
        guard let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            url = nil; isConnected = false; freeBytes = nil; totalBytes = nil
            return
        }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) else {
            url = nil; isConnected = false; freeBytes = nil; totalBytes = nil
            return
        }
        if scopedURL?.path != resolved.path {
            stopScope()
            if resolved.startAccessingSecurityScopedResource() { scopedURL = resolved }
        }
        if stale, let fresh = try? resolved.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
        }

        let connected = Self.looksLikeRockbox(resolved)
        isConnected = connected
        url = connected ? resolved : nil
        name = resolved.lastPathComponent
        let space = connected ? Self.space(of: resolved) : nil
        freeBytes = space?.free
        totalBytes = space?.total
    }

    private func stopScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    nonisolated static func looksLikeRockbox(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(".rockbox").path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Free and total bytes of the volume; read fresh, URLs cache their resource values.
    nonisolated static func space(of url: URL) -> (free: Int64, total: Int64)? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacity, let total = values.volumeTotalCapacity else { return nil }
        return (Int64(free), Int64(total))
    }
}
#endif
