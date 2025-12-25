// In Views/Shared/AlbumGridItemView.swift
import SwiftUI

struct AlbumGridItemView: View {
    // Non dipende più dal viewModel! -> ora dipende per il pulsante preferiti
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem
    let artworkURL: URL? // Riceve l'URL direttamente
    
    var body: some View {
        VStack(alignment: .leading) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(url: artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Rectangle().foregroundColor(.secondary.opacity(0.3))
                        .overlay(Image(systemName: "music.note").font(.largeTitle))
                }
                .cornerRadius(8)
                .shadow(radius: 4)
                
                // Favorite button in overlay
                Button(action: {
                    viewModel.toggleFavoriteAlbum(album.id)
                }) {
                    Image(systemName: viewModel.isAlbumFavorite(album.id) ? "heart.fill" : "heart")
                        .foregroundColor(viewModel.isAlbumFavorite(album.id) ? .red : .white)
                        .padding(8)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .padding(8)
            }
            
            Text(album.Name).font(.headline).lineLimit(1)
            Text(album.AlbumArtist ?? "Artista Sconosciuto").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
        }
    }
}
