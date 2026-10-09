// MusicLibrarySelection.swift
// Which of the server's music libraries Ampfin shows. The server decides what a user can
// see (/Views); this is only a client-side filter on top. What is stored is the libraries
// switched OFF, per server and user, so a library that shows up later is on by default and
// one that disappears is simply ignored.

import Foundation

enum MusicLibrarySelection {
    static let storageKey = "disabledMusicLibraries"

    /// "server|user" -> ids of the libraries switched off.
    private static var stored: [String: [String]] {
        UserDefaults.standard.dictionary(forKey: storageKey) as? [String: [String]] ?? [:]
    }

    static func disabledIds(scope: String) -> Set<String> {
        Set(stored[scope] ?? [])
    }

    /// The libraries to use. If everything is off (or the off ones are gone), all of them,
    /// so the app never ends up with an empty library.
    static func enabled(from libraries: [LibraryView], scope: String) -> [LibraryView] {
        let off = disabledIds(scope: scope)
        let on = libraries.filter { !off.contains($0.Id) }
        return on.isEmpty ? libraries : on
    }

    static func isEnabled(_ id: String, in libraries: [LibraryView], scope: String) -> Bool {
        enabled(from: libraries, scope: scope).contains { $0.Id == id }
    }

    /// Switches a library on or off. The last one still on can't be switched off.
    static func setEnabled(_ isOn: Bool, id: String, in libraries: [LibraryView], scope: String) {
        var off = disabledIds(scope: scope)
        if isOn {
            off.remove(id)
        } else {
            off.insert(id)
            guard libraries.contains(where: { !off.contains($0.Id) }) else { return }
        }
        var all = stored
        all[scope] = off.isEmpty ? nil : off.sorted()
        UserDefaults.standard.set(all, forKey: storageKey)
    }
}
