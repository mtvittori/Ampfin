// In Views/Shared/AlbumGridItemView.swift
import SwiftUI

struct AlbumGridItemView: View {
    // Non dipende più dal viewModel!
    let album: AlbumItem
    let artworkURL: URL? // Riceve l'URL direttamente
    
    var body: some View {
        VStack(alignment: .leading) {
            CachedAsyncImage(url: artworkURL) { image in // Usa la proprietà artworkURL
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Rectangle().foregroundColor(.secondary.opacity(0.3))
                    .overlay(Image(systemName: "music.note").font(.largeTitle))
            }
            .cornerRadius(8)
            .shadow(radius: 4)
            
            Text(album.Name).font(.headline).lineLimit(1)
            Text(album.AlbumArtist ?? "Artista Sconosciuto").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
        }
    }
}
