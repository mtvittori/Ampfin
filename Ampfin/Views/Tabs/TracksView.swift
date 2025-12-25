import SwiftUI

struct TracksView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var searchText = ""

    var filteredTracks: [AudioItem] {
        // prefer the global search query if present
        let query = viewModel.globalSearchQuery.isEmpty ? searchText : viewModel.globalSearchQuery
        if query.isEmpty {
            return viewModel.audioItems
        } else {
            return viewModel.audioItems.filter {
                $0.Name.localizedCaseInsensitiveContains(query) ||
                ($0.mainArtistName ?? "").localizedCaseInsensitiveContains(query) ||
                ($0.Album ?? "").localizedCaseInsensitiveContains(query)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            List(filteredTracks) { item in
                let artworkURL = viewModel.artworkURL(for: item.id, size: 80)
                
                HStack(spacing: 10) {
                    CachedAsyncImage(url: artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
                    }
                    .frame(width: 48, height: 48)
                    .cornerRadius(6)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.Name).font(.subheadline).lineLimit(1)
                        Text(item.mainArtistName ?? "Artista Sconosciuto")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer()
                    
                    // Favorite button for tracks
                    Button(action: {
                        viewModel.toggleFavoriteTrack(item.id)
                    }) {
                        Image(systemName: viewModel.isTrackFavorite(item.id) ? "heart.fill" : "heart")
                            .foregroundColor(viewModel.isTrackFavorite(item.id) ? .red : .secondary)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.trailing, 6)
                    
                    if viewModel.currentlyPlayingItem?.id == item.id {
                        // Indicate currently playing
                        Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                            .foregroundColor(.accentColor)
                    }
                    
                    Button(action: {
                        let isCurrent = (viewModel.currentlyPlayingItem?.id == item.id)
                        if isCurrent {
                            if viewModel.isPlaying {
                                viewModel.playerManager.pause()
                            } else {
                                viewModel.playerManager.play()
                            }
                        } else {
                            viewModel.playerManager.play(item: item, in: filteredTracks)
                        }
                    }) {
                        let isCurrent = (viewModel.currentlyPlayingItem?.id == item.id)
                        let playing = viewModel.isPlaying && isCurrent
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.playerManager.play(item: item, in: filteredTracks)
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Brani")
    }
}
