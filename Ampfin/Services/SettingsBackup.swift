// SettingsBackup.swift
// Backup of the app's settings. iCloud sync needs a paid developer account, so the
// copy lives on the Jellyfin server instead (Display Preferences of client
// "amplifin", per user): it is kept up to date automatically and restored by itself on
// a fresh install. It can also be exported to a file, e.g. on iCloud Drive.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SettingsBackup: ObservableObject {
    static let shared = SettingsBackup()

    /// What travels in the backup: appearance, favorites, playback, equalizer, artist
    /// merges. Not the login (server, token, user) and not the caches.
    static let keys: [String] = [
        "accentColor_red", "accentColor_green", "accentColor_blue", "accentColor_hasCustom",
        "accentFollowsArtwork", "glassTintEnabled", "glassTintIntensity",
        "nowPlayingBlurredBackground", "albumColorBackground", "topBarStyle", "mixSource", "mixesInTopPicks", "scrobbleStatsOnHome", "letterIndexStyle", "landscapeCoverFlow", "coverFlowResumesPlaying", "heroCoverBelowIsland", "albumsSort", "tracksSort",
        "jellyfin_favorite_albums", "jellyfin_favorite_tracks", "jellyfin_favorite_playlists",
        "stream_quality_wifi", "stream_quality_cellular", "library_refresh_interval",
        "eq_enabled", "eq_preset", "eq_bandGains",
        ArtistMergeStore.autoMergeKey, ArtistMergeStore.splitCreditsKey, ArtistMergeStore.manualMergesKey,
    ]

    private static let lastServerBackupKey = "settingsBackup_lastServerDate"
    /// Set once this install has checked the server for a copy to restore.
    private static let checkedServerKey = "settingsBackup_checkedServer"

    @Published private(set) var lastServerBackup: Date?
    @Published private(set) var isWorking = false
    /// Last outcome, shown under the backup buttons.
    @Published var message: String?

    private var api: JellyfinAPIService?
    private var lastUploaded: NSDictionary?
    private var pendingUpload: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    private init() {
        lastServerBackup = UserDefaults.standard.object(forKey: Self.lastServerBackupKey) as? Date
    }

    // MARK: - Automatic backup

    /// Called once logged in. On a fresh install (no settings of its own yet) it first
    /// restores the server copy; an install that already has settings keeps them and
    /// becomes the backup. Afterwards every change is uploaded a few seconds later.
    func connect(api: JellyfinAPIService) async {
        self.api = api
        if !UserDefaults.standard.bool(forKey: Self.checkedServerKey) {
            guard snapshot().isEmpty else {
                UserDefaults.standard.set(true, forKey: Self.checkedServerKey)
                startObserving()
                scheduleUpload(after: .seconds(1))
                return
            }
            do {
                if let remote = try await api.loadSettingsBackup() {
                    apply(remote.settings)
                    lastUploaded = NSDictionary(dictionary: remote.settings)
                    setLastServerBackup(remote.date)
                    message = "Impostazioni ripristinate dal backup su Jellyfin."
                }
                UserDefaults.standard.set(true, forKey: Self.checkedServerKey)
            } catch {
                // Server unreachable: don't overwrite its copy with this install's defaults.
                return
            }
        }
        startObserving()
        scheduleUpload(after: .seconds(1))
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.scheduleUpload(after: .seconds(4)) }
        }
    }

    /// Waits for changes to settle (a slider sends dozens), then uploads if anything changed.
    private func scheduleUpload(after delay: Duration) {
        pendingUpload?.cancel()
        pendingUpload = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await uploadIfChanged()
        }
    }

    private func uploadIfChanged() async {
        let current = NSDictionary(dictionary: snapshot())
        guard current != lastUploaded else { return }
        await upload(current as? [String: Any] ?? [:], manual: false)
    }

    // MARK: - Buttons

    func backupNow() async {
        await upload(snapshot(), manual: true)
    }

    func restoreFromServer() async {
        guard let api else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            guard let remote = try await api.loadSettingsBackup() else {
                message = "Sul server non c'è ancora un backup."
                return
            }
            apply(remote.settings)
            lastUploaded = NSDictionary(dictionary: remote.settings)
            setLastServerBackup(remote.date)
            message = "Impostazioni ripristinate dal backup del \(remote.date.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            message = "Ripristino non riuscito: \(error.localizedDescription)"
        }
    }

    /// The file for "Esporta": JSON with the settings as a base64 property list.
    func exportFile() -> SettingsBackupFile {
        SettingsBackupFile(settings: snapshot(), date: Date())
    }

    func importFile(at url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let file = try SettingsBackupFile(data: Data(contentsOf: url))
            apply(file.settings)
            message = "Impostazioni importate dal file del \(file.date.formatted(date: .abbreviated, time: .shortened))."
        } catch {
            message = "Questo file non è un backup di amplifin."
        }
    }

    // MARK: - Snapshot

    /// Only what is really saved: launch arguments (used for tests) also show up in
    /// UserDefaults and must not end up in the backup.
    private func snapshot() -> [String: Any] {
        let saved = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
        return saved.filter { Self.keys.contains($0.key) }
    }

    /// Writes the backed-up values and makes every part of the app read them again.
    private func apply(_ settings: [String: Any]) {
        for key in Self.keys {
            if let value = settings[key] {
                UserDefaults.standard.set(value, forKey: key)
            }
        }
        AccentColorManager.shared.reload()
        EqualizerManager.shared.reloadFromDefaults()
        ArtistMergeStore.shared.reload()
        JellyfinViewModel.shared?.reloadSettingsFromDefaults()
    }

    private func upload(_ settings: [String: Any], manual: Bool) async {
        guard let api else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let date = Date()
            try await api.saveSettingsBackup(settings, date: date)
            lastUploaded = NSDictionary(dictionary: settings)
            setLastServerBackup(date)
            if manual { message = "Backup salvato su Jellyfin." }
        } catch {
            message = "Backup non riuscito: \(error.localizedDescription)"
        }
    }

    private func setLastServerBackup(_ date: Date) {
        lastServerBackup = date
        UserDefaults.standard.set(date, forKey: Self.lastServerBackupKey)
    }
}

// MARK: - Encoding

enum SettingsBackupCoding {
    static func encode(_ settings: [String: Any]) throws -> String {
        try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0).base64EncodedString()
    }

    static func decode(_ base64: String) throws -> [String: Any] {
        guard let data = Data(base64Encoded: base64),
              let settings = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return settings
    }
}

/// The exported backup: `{"app": "amplifin", "versione": 1, "data": …, "impostazioni": …}`.
struct SettingsBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let settings: [String: Any]
    let date: Date

    init(settings: [String: Any], date: Date) {
        self.settings = settings
        self.date = date
    }

    init(data: Data) throws {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["app"] as? String == "amplifin",
              let encoded = json["impostazioni"] as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        settings = try SettingsBackupCoding.decode(encoded)
        date = (json["data"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(data: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let json: [String: Any] = [
            "app": "amplifin",
            "versione": 1,
            "data": ISO8601DateFormatter().string(from: date),
            "impostazioni": try SettingsBackupCoding.encode(settings),
        ]
        return FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]))
    }

    var suggestedName: String {
        "amplifin backup \(date.formatted(.iso8601.year().month().day()))"
    }
}
