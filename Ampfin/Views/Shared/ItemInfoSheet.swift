// ItemInfoSheet.swift
// "Info brano" / "Info album": every piece of metadata Jellyfin has for a song or an
// album, read fresh from the server. Values can be selected and copied.

import SwiftUI

struct ItemInfoSheet: View {
    enum Kind { case track, album }

    @EnvironmentObject var viewModel: JellyfinViewModel
    @Environment(\.dismiss) private var dismiss

    let itemId: String
    let kind: Kind
    let title: String

    @State private var sections: [InfoSection] = []
    @State private var failed = false

    struct InfoSection: Identifiable {
        let id = UUID()
        let title: String
        let rows: [(String, String)]
    }

    var body: some View {
        NavigationStack {
            Group {
                if failed {
                    ContentUnavailableView("Informazioni non disponibili", systemImage: "exclamationmark.triangle",
                                           description: Text("Il server non ha risposto."))
                } else if sections.isEmpty {
                    ProgressView()
                } else {
                    List {
                        ForEach(sections) { section in
                            Section(section.title) {
                                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                    LabeledContent(row.0) {
                                        Text(row.1)
                                            .multilineTextAlignment(.trailing)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .task(id: itemId) {
            guard let json = await viewModel.itemDetails(id: itemId) else {
                failed = true
                return
            }
            sections = kind == .track ? Self.trackSections(json) : Self.albumSections(json, tracks: viewModel.selectedAlbumTracks)
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Song

    private static func trackSections(_ json: [String: Any]) -> [InfoSection] {
        var general: [(String, String)] = []
        add(&general, "Titolo", json["Name"] as? String)
        add(&general, "Artisti", (json["Artists"] as? [String])?.joined(separator: ", "))
        add(&general, "Artista album", json["AlbumArtist"] as? String)
        add(&general, "Album", json["Album"] as? String)
        add(&general, "Traccia", (json["IndexNumber"] as? Int).map(String.init))
        add(&general, "Disco", (json["ParentIndexNumber"] as? Int).map(String.init))
        add(&general, "Anno", (json["ProductionYear"] as? Int).map(String.init))
        add(&general, "Generi", (json["Genres"] as? [String])?.joined(separator: ", "))
        add(&general, "Compositori", people(json, type: "Composer"))
        add(&general, "Durata", duration(json["RunTimeTicks"]))
        add(&general, "Testo", (json["HasLyrics"] as? Bool).map { $0 ? "Sì" : "No" })

        var file: [(String, String)] = []
        let source = (json["MediaSources"] as? [[String: Any]])?.first
        let audio = (source?["MediaStreams"] as? [[String: Any]])?.first { $0["Type"] as? String == "Audio" }
        add(&file, "Formato", (source?["Container"] as? String ?? json["Container"] as? String)?.uppercased())
        add(&file, "Codec", (audio?["Codec"] as? String)?.uppercased())
        add(&file, "Bitrate", (audio?["BitRate"] as? Int ?? source?["Bitrate"] as? Int).map { "\($0 / 1000) kbps" })
        add(&file, "Frequenza", (audio?["SampleRate"] as? Int).map { AudioInfoFormat.sampleRate(Double($0)) })
        add(&file, "Profondità", (audio?["BitDepth"] as? Int).map { "\($0) bit" })
        add(&file, "Canali", (audio?["Channels"] as? Int).map(channels))
        add(&file, "Dimensione", (source?["Size"] as? Int64 ?? (source?["Size"] as? Int).map(Int64.init)).map(bytes))
        add(&file, "Percorso", source?["Path"] as? String ?? json["Path"] as? String)
        add(&file, "Aggiunto il", date(json["DateCreated"]))

        var volume: [(String, String)] = []
        add(&volume, "Normalizzazione", (json["NormalizationGain"] as? Double).map { String(format: "%+.1f dB", $0) })
        add(&volume, "Loudness", (json["LUFS"] as? Double).map { String(format: "%.1f LUFS", $0) })

        return [InfoSection(title: "Brano", rows: general), InfoSection(title: "File", rows: file),
                InfoSection(title: "Volume", rows: volume), InfoSection(title: "Identificativi", rows: ids(json))]
            .filter { !$0.rows.isEmpty }
    }

    // MARK: - Album

    private static func albumSections(_ json: [String: Any], tracks: [AudioItem]) -> [InfoSection] {
        var general: [(String, String)] = []
        add(&general, "Titolo", json["Name"] as? String)
        add(&general, "Artista", json["AlbumArtist"] as? String)
        add(&general, "Anno", (json["ProductionYear"] as? Int).map(String.init))
        add(&general, "Uscita", date(json["PremiereDate"]))
        add(&general, "Generi", (json["Genres"] as? [String])?.joined(separator: ", "))
        add(&general, "Etichetta", (json["Studios"] as? [[String: Any]])?.compactMap { $0["Name"] as? String }.joined(separator: ", "))
        add(&general, "Brani", (json["ChildCount"] as? Int).map(String.init))
        add(&general, "Durata", duration(json["CumulativeRunTimeTicks"] ?? json["RunTimeTicks"]))
        add(&general, "Descrizione", json["Overview"] as? String)

        var file: [(String, String)] = []
        let containers = Set(tracks.compactMap { $0.MediaSources?.first?.Container?.uppercased() })
        add(&file, "Formati", containers.sorted().joined(separator: ", "))
        let rates = Set(tracks.compactMap { $0.MediaSources?.first?.MediaStreams?.first?.SampleRate })
        add(&file, "Frequenze", rates.sorted().map { AudioInfoFormat.sampleRate(Double($0)) }.joined(separator: ", "))
        let depths = Set(tracks.compactMap { $0.MediaSources?.first?.MediaStreams?.first?.BitDepth })
        add(&file, "Profondità", depths.sorted().map { "\($0) bit" }.joined(separator: ", "))
        add(&file, "Percorso", json["Path"] as? String)
        add(&file, "Aggiunto il", date(json["DateCreated"]))

        return [InfoSection(title: "Album", rows: general), InfoSection(title: "File", rows: file),
                InfoSection(title: "Identificativi", rows: ids(json))]
            .filter { !$0.rows.isEmpty }
    }

    // MARK: - Helpers

    private static func add(_ rows: inout [(String, String)], _ label: String, _ value: String?) {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        rows.append((label, value.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private static func people(_ json: [String: Any], type: String) -> String? {
        (json["People"] as? [[String: Any]])?
            .filter { $0["Type"] as? String == type }
            .compactMap { $0["Name"] as? String }
            .joined(separator: ", ")
    }

    private static func ids(_ json: [String: Any]) -> [(String, String)] {
        var rows: [(String, String)] = []
        let names = ["MusicBrainzTrack": "MusicBrainz brano", "MusicBrainzRecording": "MusicBrainz registrazione",
                     "MusicBrainzAlbum": "MusicBrainz album", "MusicBrainzReleaseGroup": "MusicBrainz release group",
                     "MusicBrainzAlbumArtist": "MusicBrainz artista album", "MusicBrainzArtist": "MusicBrainz artista"]
        for (key, value) in (json["ProviderIds"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
            add(&rows, names[key] ?? key, value)
        }
        add(&rows, "Jellyfin", json["Id"] as? String)
        return rows
    }

    private static func duration(_ ticks: Any?) -> String? {
        guard let ticks = (ticks as? NSNumber)?.doubleValue, ticks > 0 else { return nil }
        let seconds = Int(ticks / 10_000_000)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func date(_ value: Any?) -> String? {
        guard let text = value as? String, !text.hasPrefix("0001") else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: text) ?? ISO8601DateFormatter().date(from: String(text.prefix(19)) + "Z")
        return parsed?.formatted(date: .long, time: .omitted)
    }

    private static func channels(_ count: Int) -> String {
        switch count {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return "\(count) canali"
        }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
