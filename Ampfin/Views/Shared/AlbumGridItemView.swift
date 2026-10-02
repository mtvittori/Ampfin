// In Views/Shared/AlbumGridItemView.swift
import SwiftUI

struct AlbumGridItemView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem
    let artworkURL: URL?
    
    var body: some View {
        VStack(alignment: .leading) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(url: artworkURL, targetSize: 300) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Rectangle().foregroundColor(.secondary.opacity(0.3))
                        .overlay(Image(systemName: "music.note").font(.largeTitle))
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                
                // Favorite button with Liquid Glass
                Button(action: {
                    viewModel.toggleFavoriteAlbum(album.id)
                }) {
                    Image(systemName: viewModel.isAlbumFavorite(album.id) ? "heart.fill" : "heart")
                        .foregroundColor(viewModel.isAlbumFavorite(album.id) ? .red : .white)
                        .font(.callout)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .padding(6)
            }
            
            Text(album.Name).font(.headline).lineLimit(1)
            Text(album.AlbumArtist ?? "Artista Sconosciuto").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
        }
    }
}
