// In Views/Tabs/AlbumsView.swift
import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 20)]
    
    // If the global search query is present, filter albums accordingly
    private var displayedAlbums: [AlbumItem] {
        let query = viewModel.globalSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return viewModel.albums
        } else {
            return viewModel.albums.filter {
                $0.Name.localizedCaseInsensitiveContains(query) ||
                ($0.AlbumArtist ?? "").localizedCaseInsensitiveContains(query) ||
                ($0.Genres?.joined(separator: " ").localizedCaseInsensitiveContains(query) ?? false)
            }
        }
    }

    var body: some View {
        NavigationStack {
            // Usare ScrollView + LazyVGrid evita che l'intera riga di List venga selezionata
            ScrollView {
                VStack(spacing: 0) {
                    if displayedAlbums.isEmpty {
                        VStack {
                            Text("Nessun album trovato.")
                                .foregroundColor(.secondary)
                                .padding()
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                    } else {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(displayedAlbums) { album in
                                NavigationLink(destination: AlbumTracksListView(album: album)) {
                                    AlbumGridItemView(album: album, artworkURL: viewModel.artworkURL(for: album.id, size: 300))
                                        .frame(minWidth: 140, minHeight: 160)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top)
                        .padding(.bottom, 40) // lascia spazio per eventuale player overlay
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .background(Color.clear)
            .navigationTitle("Album")
            // Manteniamo la navigationDestination per compatibilità con altre parti dell'app
            .navigationDestination(for: AlbumItem.self) { album in
                AlbumTracksListView(album: album)
            }
        }
    }
}
