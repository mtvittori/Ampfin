// ArtistMergeViews.swift
// Settings → Unisci artisti, and the sheet that merges artists by hand.

import SwiftUI

struct ArtistMergeSettingsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = ArtistMergeStore.shared
    @State private var showMergeSheet = false

    var body: some View {
        List {
            Section {
                Toggle("Unisci i doppioni", isOn: $store.autoMergeDuplicates)
                Toggle("Separa i featuring", isOn: $store.splitCredits)
            } header: {
                Text("Automatico")
            } footer: {
                Text("Doppioni: lo stesso nome scritto con maiuscole, accenti o \"(…)\" diversi diventa un solo artista. Featuring: \"A feat. B\" o \"A, B\" compare sotto A e sotto B invece che come artista a parte; \"Daisy Jones & The Six\" o \"Simon & Garfunkel\" restano interi. Oggi \(viewModel.artists.count) artisti da \(viewModel.rawArtistCount) voci del server; il server non viene modificato.")
            }

            Section {
                if store.manualGroups.isEmpty {
                    Text("Nessuna unione fatta a mano.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.manualGroups, id: \.root) { group in
                        groupRow(group)
                            .swipeActions {
                                Button("Separa", role: .destructive) {
                                    withAnimation { store.separateGroup(root: group.root) }
                                }
                            }
                            .contextMenu {
                                Button("Separa", systemImage: "arrow.triangle.branch", role: .destructive) {
                                    withAnimation { store.separateGroup(root: group.root) }
                                }
                            }
                    }
                }

                Button("Unisci artisti…", systemImage: "arrow.triangle.merge") {
                    showMergeSheet = true
                }
            } header: {
                Text("A mano")
            } footer: {
                Text("Per i casi che l'automatico non vede. Si può anche tenere premuto un artista nella scheda Artisti. Le unioni finiscono nel backup delle impostazioni.")
            }
        }
        .navigationTitle("Unisci artisti")
        .sheet(isPresented: $showMergeSheet) {
            MergeArtistsSheet(main: nil)
                .environmentObject(viewModel)
        }
    }

    private func groupRow(_ group: (root: String, members: [String])) -> some View {
        let main = viewModel.artist(forKey: group.root)
        let others = (main?.mergedNames ?? []).filter { ArtistMergeStore.key($0) != group.root }

        return VStack(alignment: .leading, spacing: 2) {
            Text(main?.Name ?? group.root)
                .font(.body.weight(.semibold))
            Text(Set(others).sorted().joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
    }
}

/// Pick the main artist (unless given), then the ones to fold into it.
struct MergeArtistsSheet: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Environment(\.dismiss) private var dismiss

    @State var main: ArtistItem?
    @State private var selected: Set<String> = []
    @State private var query = ""

    private var candidates: [ArtistItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return viewModel.artists.filter { artist in
            artist.Id != main?.Id && (q.isEmpty || artist.Name.localizedCaseInsensitiveContains(q))
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if let main {
                    Section {
                        Label(main.Name, systemImage: "music.mic")
                            .font(.body.weight(.semibold))
                    } header: {
                        Text("Artista principale")
                    }
                }

                Section {
                    ForEach(candidates) { artist in
                        Button {
                            pick(artist)
                        } label: {
                            HStack {
                                Text(artist.Name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if main != nil {
                                    Image(systemName: selected.contains(artist.Id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(artist.Id) ? Color.accentColor : .secondary)
                                        .contentTransition(.symbolEffect(.replace))
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                } header: {
                    Text(main == nil ? "Scegli l'artista principale" : "Da unire a \(main?.Name ?? "")")
                }
            }
            .searchable(text: $query, prompt: "Cerca un artista")
            .navigationTitle("Unisci artisti")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Unisci (\(selected.count))") {
                        merge()
                    }
                    .disabled(main == nil || selected.isEmpty)
                }
            }
        }
    }

    private func pick(_ artist: ArtistItem) {
        if main == nil {
            withAnimation { main = artist }
            query = ""
        } else if selected.contains(artist.Id) {
            selected.remove(artist.Id)
        } else {
            selected.insert(artist.Id)
        }
    }

    private func merge() {
        guard let main else { return }
        let others = viewModel.artists.filter { selected.contains($0.Id) }
        ArtistMergeStore.shared.merge(others, into: main)
        dismiss()
    }
}

/// Long press on an artist: "Unisci con altri artisti…".
struct MergeArtistMenu: ViewModifier {
    let artist: ArtistItem
    @Binding var target: ArtistItem?

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Unisci con altri artisti…", systemImage: "arrow.triangle.merge") {
                target = artist
            }
            if let names = artist.mergedNames, names.count > 1,
               ArtistMergeStore.shared.isManual(ArtistMergeStore.key(artist.Name)) {
                Button("Separa", systemImage: "arrow.triangle.branch", role: .destructive) {
                    ArtistMergeStore.shared.separateGroup(root: ArtistMergeStore.shared.resolve(ArtistMergeStore.key(artist.Name)))
                }
            }
        }
    }
}

extension View {
    func mergeArtistMenu(_ artist: ArtistItem, target: Binding<ArtistItem?>) -> some View {
        modifier(MergeArtistMenu(artist: artist, target: target))
    }
}
