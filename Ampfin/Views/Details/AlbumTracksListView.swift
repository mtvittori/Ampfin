import SwiftUI

struct AlbumTracksListView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem

    var body: some View {
        List {
            albumHeader
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .padding(.bottom)

            if viewModel.isLoadingAlbum {
                ProgressView()
            } else {
                ForEach(Array(viewModel.selectedAlbumTracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track: track, index: index)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.Name)
        .task { // Usa .task per le operazioni async in SwiftUI
            await viewModel.fetchAlbumTracks(albumId: album.id)
        }
    }
    
    private var albumHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                AsyncImage(url: viewModel.artworkURL(for: album.id, size: 360)) { $0.resizable().aspectRatio(contentMode: .fit) }
                placeholder: { Rectangle().fill(.gray.opacity(0.3)).overlay(Image(systemName: "music.note")) }
                .frame(width: 180, height: 180).cornerRadius(8).shadow(radius: 5)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.Name).font(.title).fontWeight(.bold)
                    Text(album.AlbumArtist ?? "Artista Sconosciuto").font(.title3).foregroundColor(.accentColor)
                    // Altre info...
                }.padding(.top, 5)
                Spacer()
            }
            
            HStack {
                Button {
                    if let firstTrack = viewModel.selectedAlbumTracks.first {
                        viewModel.playerManager.play(item: firstTrack, in: viewModel.selectedAlbumTracks)
                    }
                } label: { Label("Riproduci", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
                
                Button {
                    viewModel.playerManager.playAlbumShuffled(tracks: viewModel.selectedAlbumTracks)
                } label: { Label("Casuale", systemImage: "shuffle").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).controlSize(.large)
                
                Button(action: { viewModel.toggleRepeatMode() }) {
                    Image(systemName: viewModel.repeatMode.iconName)
                        .foregroundColor(viewModel.repeatMode == .off ? .primary : .accentColor)
                }
                .accessibilityLabel("Repeat mode")
                .help("Repeat: \(viewModel.repeatMode)")
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }.padding([.horizontal, .top])
    }
    
    private func trackRow(track: AudioItem, index: Int) -> some View {
        HStack {
            Text("\(index + 1)").font(.callout).foregroundColor(.secondary).frame(minWidth: 32, alignment: .trailing)
            Text(track.Name).font(.body)
            if track.isLossless {
                Label("FLAC", systemImage: "waveform")
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
            
            // Favorite button for track
            Button(action: {
                viewModel.toggleFavoriteTrack(track.id)
            }) {
                Image(systemName: viewModel.isTrackFavorite(track.id) ? "heart.fill" : "heart")
                    .foregroundColor(viewModel.isTrackFavorite(track.id) ? .red : .secondary)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 8)
            
            if viewModel.currentlyPlayingItem?.id == track.id {
                Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                    .foregroundColor(.accentColor)
            }
            Text(formatTime(track.duration ?? 0)).font(.callout).foregroundColor(.secondary)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.playerManager.play(item: track, in: viewModel.selectedAlbumTracks)
        }
    }
    
    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
