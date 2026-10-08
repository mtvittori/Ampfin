import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    /// Apple Music-style: Play / Shuffle on the favorite songs, the favorite albums as a
    /// strip of covers, then the songs with their covers; swipes and long press queue them.
    var body: some View {
        #if os(macOS)
        MacFavoritesView()
        #else
        phoneBody
        #endif
    }

    @ViewBuilder
    private var phoneBody: some View {
        let tracks = viewModel.favoriteTracks
        let albums = viewModel.favoriteAlbums

        if tracks.isEmpty && albums.isEmpty {
            ContentUnavailableView("Nessun preferito", systemImage: "heart",
                                   description: Text("Tocca il cuore su un album, o tieni premuto un brano, per ritrovarli qui."))
                .navigationTitle("Preferiti")
                .albumColorBackground()
        } else {
            List {
                if !tracks.isEmpty {
                    LibraryPlayButtons(tracks: tracks) { DownloadAllButton(tracks: tracks) }
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .albumBackdropRow()
                        .entrance(.rise)
                }

                if !albums.isEmpty {
                    sectionTitle("Album", count: albums.count)
                    AlbumStrip(albums: albums, group: "favorites")
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
                        .albumBackdropRow()
                        .entrance(.rise, delay: 0.06)
                }

                if !tracks.isEmpty {
                    sectionTitle("Brani", count: tracks.count)
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        FavoriteTrackRow(track: track, queue: tracks)
                            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                            .albumBackdropRow()
                            .queueSwipeActions(track, viewModel: viewModel)
                            .entrance(.slide, delay: 0.1 + Double(index) * 0.03, enabled: index < 12)
                    }
                }
            }
            .listStyle(.plain)
            .contentMargins(.bottom, 170)
            .navigationTitle("Preferiti")
            .albumColorBackground()
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title2.weight(.bold))
            Text("\(count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 6, trailing: 20))
        .albumBackdropRow()
        .accessibilityAddTraits(.isHeader)
    }
}

/// A favorite song: cover, title, artist, the wave while it plays, and a heart to
/// take it out of the favorites.
private struct FavoriteTrackRow: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared
    let track: AudioItem
    let queue: [AudioItem]

    private var isCurrent: Bool { viewModel.currentlyPlayingItem?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.playerManager.play(item: track, in: queue)
            } label: {
                HStack(spacing: 12) {
                    CachedAsyncImage(url: viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 160), targetSize: 52,
                        content: { $0.resizable().aspectRatio(contentMode: .fill) },
                        placeholder: { RoundedRectangle(cornerRadius: 8).fill(.quaternary) }
                    )
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.Name)
                            .font(.body)
                            .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                            .lineLimit(1)
                        Text(viewModel.artistName(for: track) ?? "")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if downloadManager.isDownloaded(track.Id) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Scaricato")
            }

            if isCurrent {
                Image(systemName: viewModel.isPlaying ? "waveform" : "pause.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: viewModel.isPlaying)
            }

            Button {
                withAnimation { viewModel.toggleFavoriteTrack(track.id) }
            } label: {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rimuovi dai preferiti")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                viewModel.playerManager.play(item: track, in: queue)
            } label: {
                Label("Riproduci", systemImage: "play.fill")
            }
            QueueMenuItems(tracks: [track])
            Divider()
            TrackNavigationMenuItems(track: track)
            Divider()
            Button(role: .destructive) {
                withAnimation { viewModel.toggleFavoriteTrack(track.id) }
            } label: {
                Label("Rimuovi dai preferiti", systemImage: "heart.slash")
            }
        }
    }
}

/// Downloads every favorite song to the phone, a few at a time, as the third button
/// next to Play and Shuffle: an arrow, then a ring that fills (tap to stop), then a tick.
/// iOS keeps it going in the background and shows it as a live activity.
struct DownloadAllButton: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared
    let tracks: [AudioItem]

    var body: some View {
        let states = tracks.map { downloadManager.downloadStates[$0.Id] ?? .notDownloaded }
        let done = states.filter { $0 == .downloaded }.count
        let inProgress = states.contains { if case .downloading = $0 { return true } else { return false } }
        let missing = tracks.count - done

        Button {
            if inProgress {
                // Stop what hasn't finished; the songs already saved stay.
                for (track, state) in zip(tracks, states) {
                    if case .downloading = state { viewModel.removeDownload(for: track.Id) }
                }
            } else {
                tracks.filter { !downloadManager.isDownloaded($0.Id) }.forEach(viewModel.downloadTrack)
            }
        } label: {
            LibraryRowIcon {
                if inProgress {
                    ZStack {
                        Circle()
                            .stroke(.tint.opacity(0.25), lineWidth: 2.5)
                        Circle()
                            .trim(from: 0, to: Double(done) / Double(max(tracks.count, 1)))
                            .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .frame(width: 22, height: 22)
                    .animation(.snappy, value: done)
                } else {
                    Image(systemName: missing == 0 ? "checkmark" : "arrow.down")
                        .foregroundStyle(missing == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(missing == 0)
        .accessibilityLabel(missing == 0 ? "Tutti i preferiti sono scaricati"
                            : inProgress ? "Download \(done) di \(tracks.count), tocca per fermare"
                            : "Scarica tutti i preferiti (\(missing))")
    }
}
