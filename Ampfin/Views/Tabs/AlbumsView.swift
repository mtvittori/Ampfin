// In Views/Tabs/AlbumsView.swift
import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 20)]
    
    // 1. Stato per la navigazione programmatica
    @State private var selectedAlbum: AlbumItem?

    var body: some View {
        NavigationStack {
            List {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(viewModel.albums) { album in
                        let artworkURL = viewModel.artworkURL(for: album.id, size: 300)
                        
                        // 2. Usiamo un Button invece di un NavigationLink diretto
                        Button(action: {
                            // Quando si clicca, impostiamo l'album selezionato
                            selectedAlbum = album
                        }) {
                            AlbumGridItemView(album: album, artworkURL: artworkURL)
                                .drawingGroup()
                        }
                        .buttonStyle(.plain) // Mantiene l'aspetto pulito
                    }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .padding(.horizontal)
                .padding(.bottom)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .navigationTitle("Album")
            
            // 3. NavigationLink invisibile, attivato dallo stato
            // Lo mettiamo in background per non influenzare il layout.
            .background(
                NavigationLink(
                    tag: selectedAlbum ?? viewModel.albums.first!, // Usa un valore di fallback valido
                    selection: $selectedAlbum,
                    destination: {
                        // Assicurati che selectedAlbum non sia nil prima di usarlo
                        if let albumToView = selectedAlbum {
                            AlbumTracksListView(album: albumToView)
                        } else {
                            // Vista di fallback nel caso improbabile sia nil
                            EmptyView()
                        }
                    },
                    label: { EmptyView() }
                )
            )
            // La vecchia navigationDestination non serve più con questo approccio
        }
    }
}
