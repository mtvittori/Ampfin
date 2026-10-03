// In Views/Tabs/AlbumsView.swift
import SwiftUI

struct AlbumsView: View {
    @ObservedObject private var colorManager = AccentColorManager.shared
    @Environment(\.zunePivotHeaderHeight) private var pivotHeader
    @EnvironmentObject var viewModel: JellyfinViewModel
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 20)]
    @State private var coverAlbum: AlbumItem?
    
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
        if pivotHeader > 0 {
            ZuneAlbumsView(albums: displayedAlbums)
        } else if colorManager.zuneStyleEnabled {
            NavigationStack {
                ZuneAlbumsView(albums: displayedAlbums)
                    .navigationDestination(for: AlbumItem.self) { album in
                        AlbumTracksListView(album: album)
                    }
            }
        } else {
            classicBody
        }
    }

    /// On iPhone the tab's own navigation stack (ContentView) is the only one: a nested
    /// stack here would carry the custom top bar into the album pages it opens.
    @ViewBuilder
    private var classicBody: some View {
        #if os(iOS)
        albumsGrid
        #else
        NavigationStack {
            albumsGrid
        }
        #endif
    }

    private var albumsGrid: some View {
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
                            NavigationLink(destination: AlbumTracksListView(album: album).zoomDestination("albums-\(album.id)")) {
                                AlbumGridItemView(album: album, artworkURL: viewModel.artworkURL(for: album.id, size: 300),
                                                  zoomID: "albums-\(album.id)")
                                    .frame(minWidth: 140, minHeight: 160)
                            }
                            .buttonStyle(.pressable)
                            .contextMenu {
                                Button("Cambia copertina", systemImage: "photo") { coverAlbum = album }
                            }
                            .gridSettle()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 170) // lascia spazio per mini player overlay
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.clear)
        #if os(iOS)
        .hidesMiniPlayerOnScroll()
        #endif
        .refreshable {
            await viewModel.fetchAllLibraryData()
        }
        .navigationTitle("Album")
        // Manteniamo la navigationDestination per compatibilità con altre parti dell'app
        .navigationDestination(for: AlbumItem.self) { album in
            AlbumTracksListView(album: album)
        }
        .sheet(item: $coverAlbum) { album in
            AlbumCoverPicker(album: album)
                .environmentObject(viewModel)
        }
    }
}
