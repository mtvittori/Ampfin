import SwiftUI

struct TrackRowView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let item: AudioItem
    let artworkURL: URL?
    let isPlaying: Bool // Riceve solo se questa traccia è in riproduzione


    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: viewModel.artworkURL(for: item.id, size: 80)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
            }
            .frame(width: 45, height: 45)
            .cornerRadius(6)

            VStack(alignment: .leading) {
                Text(item.Name).fontWeight(.medium)
                if item.isLossless {
                    Label("FLAC", systemImage: "waveform")
                        .font(.caption2)
                        .foregroundColor(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }
                HStack(spacing: 4) {
                    Text(item.mainArtistName ?? "Artista Sconosciuto").foregroundColor(.secondary)
                    Text("•").foregroundColor(.secondary)
                    Text(item.Album ?? "Album Sconosciuto").foregroundColor(.secondary)
                }
                .font(.caption)
            }
            
            Spacer()

            if isPlaying { // Usa la proprietà `isPlaying`
                            Image(systemName: "waveform").foregroundColor(.accentColor).font(.caption)
                        }
        }
        .padding(.vertical, 4)
    }
}
