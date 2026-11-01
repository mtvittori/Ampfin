// MacIPodPage.swift
// The "iPod" section: which volume is the iPod, what to put on it, in which format, and the
// Sincronizza button. Artists, albums and playlists are added from their context menus
// (IPodMenuItems).

#if os(macOS)
import SwiftUI

/// "Aggiungi all'iPod" / "Togli dall'iPod", for the context menu of an artist, album or playlist.
struct IPodMenuItems: View {
    @ObservedObject private var selection = IPodSelection.shared
    let kind: IPodSelectionEntry.Kind
    let id: String
    let name: String

    var body: some View {
        let selected = selection.contains(kind, id: id)
        Button {
            selection.toggle(kind, id: id, name: name)
        } label: {
            Label(selected ? "Togli dall'iPod" : "Aggiungi all'iPod", systemImage: selected ? "minus.circle" : "ipod")
        }
    }
}

struct MacIPodPage: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var volume = IPodVolume.shared
    @ObservedObject private var selection = IPodSelection.shared
    @ObservedObject private var sync = IPodSync.shared
    @AppStorage(IPodFormat.storageKey) private var formatRaw = IPodFormat.aac256.rawValue

    private var format: IPodFormat { IPodFormat(rawValue: formatRaw) ?? .aac256 }

    /// Changes whenever the numbers in the list have to be worked out again.
    private var statsKey: String {
        selection.entries.map(\.id).joined(separator: ",") + "|\(formatRaw)|\(viewModel.audioItems.count)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                MacPageHeader(title: "iPod", subtitle: "Copia sull'iPod con Rockbox la musica che scegli")
                volumeSection
                selectionSection
                formatSection
                syncSection
            }
            .padding(28)
        }
        .macScrollTracking()
        .navigationTitle("iPod")
        .onAppear { volume.refresh() }
        .task(id: statsKey) { await sync.refreshStats(viewModel: viewModel) }
    }

    // MARK: - Volume

    private var volumeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacSectionTitle(title: "Volume")
            HStack(spacing: 14) {
                Image(systemName: "ipod")
                    .font(.system(size: 34))
                    .foregroundStyle(volume.isConnected ? Color.accentColor : Color.secondary)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 3) {
                    if let name = volume.name {
                        Text(name).font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(volume.isConnected ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text(volume.isConnected ? "Collegato" : "Non collegato")
                        }
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        if let free = volume.freeBytes, let total = volume.totalBytes {
                            Text("\(Self.size(Int64(free))) liberi su \(Self.size(Int64(total)))")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Nessun iPod scelto").font(.headline)
                        Text("Collega l'iPod e scegli il suo volume (quello con la cartella .rockbox).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                Button(volume.hasVolume ? "Cambia iPod…" : "Scegli iPod…") { volume.choose() }
                if volume.hasVolume {
                    Button("Dimentica", role: .destructive) { volume.forget() }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if let message = volume.message {
                Text(message).font(.callout).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Selection

    private var selectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacSectionTitle(title: "Selezione")
            if selection.entries.isEmpty {
                Text("Niente ancora: tasto destro su un artista, un album o una playlist e scegli “Aggiungi all'iPod”.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(selection.entries.enumerated()), id: \.element.id) { index, entry in
                        row(entry, striped: index.isMultiple(of: 2))
                    }
                }
                totalLine
            }
        }
    }

    private func row(_ entry: IPodSelectionEntry, striped: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                Text(entry.kind.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let stats = sync.stats[entry.id] {
                Text("\(stats.tracks == 1 ? "1 brano" : "\(stats.tracks) brani") · \(Self.size(stats.bytes))")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Button {
                selection.remove(entry)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Togli dall'iPod")
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(striped ? AnyShapeStyle(.primary.opacity(0.035)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var totalLine: some View {
        let total = selection.entries.reduce(Int64(0)) { $0 + (sync.stats[$1.id]?.bytes ?? 0) }
        let free = volume.freeBytes
        let tooBig = free.map { total > $0 } ?? false
        return HStack {
            Text("Totale stimato: \(Self.size(total))")
            if let free { Text("· liberi sull'iPod: \(Self.size(free))") }
            if tooBig { Text("Non ci sta").foregroundStyle(.red).fontWeight(.semibold) }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
    }

    // MARK: - Format

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacSectionTitle(title: "Formato")
            Picker("Formato dei file lossless", selection: $formatRaw) {
                ForEach(IPodFormat.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .frame(maxWidth: 420)
            Text("I file lossy (mp3, m4a, aac, ogg, opus) vengono sempre copiati così come sono. L'AAC consuma un po' più batteria dell'MP3 su questo iPod.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            MacSectionTitle(title: "Sincronizzazione")
            if sync.isRunning {
                runningView
            } else {
                Button {
                    sync.start(viewModel: viewModel)
                } label: {
                    Label("Sincronizza", systemImage: "arrow.triangle.2.circlepath").frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!volume.isConnected)
                if !volume.isConnected {
                    Text("Collega l'iPod per sincronizzare.").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let summary = sync.summary { summaryView(summary) }
        }
    }

    private var runningView: some View {
        let progress = sync.progress ?? IPodProgress()
        return VStack(alignment: .leading, spacing: 8) {
            switch progress.phase {
            case .preparing:
                ProgressView().controlSize(.small)
                Text("Preparo l'elenco dei brani…")
            case .removing:
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text("Tolgo i brani non più selezionati: \(progress.done) di \(progress.total)")
            case .copying:
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text("Brano \(min(progress.done + 1, progress.total)) di \(progress.total) · \(Self.size(progress.bytes)) scritti")
                if let title = progress.currentTitle {
                    Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            case .playlists:
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                Text("Scrivo le playlist…")
            }
            Button("Annulla", role: .cancel) { sync.cancel() }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private func summaryView(_ summary: IPodSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let reason = summary.stopReason {
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack(spacing: 18) {
                Text("Aggiunti: \(summary.added)")
                Text("Rimossi: \(summary.removed)")
                Text("Saltati: \(summary.skipped)")
                Text("Errori: \(summary.errors.count)")
            }
            .monospacedDigit()
            if !summary.errors.isEmpty {
                DisclosureGroup("Dettagli") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(summary.errors.prefix(200).enumerated()), id: \.offset) { _, error in
                            Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }
                .frame(maxWidth: 620)
            }
            Text("Sull'iPod: Impostazioni › Impostazioni generali › Database › Inizializza ora (o attiva Aggiornamento automatico).")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }
}
#endif
