import SwiftUI

struct TracksView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var searchText = ""

    var filteredTracks: [AudioItem] {
        // On iPhone the search field filters only the Cerca tab; on the Mac the toolbar
        // search filters the section in view.
        #if os(macOS)
        let query = viewModel.globalSearchQuery.isEmpty ? searchText : viewModel.globalSearchQuery
        #else
        let query = searchText
        #endif
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
    
    @AppStorage("tracksSort") private var sort: TrackSort = .name
    /// Sorted and grouped by letter once per change: 8.000 songs are too many to sort at
    /// every redraw.
    @State private var sections: [LetterSection<AudioItem>] = []
    @State private var queue: [AudioItem] = []
    @AppStorage(LetterIndexStyle.storageKey) private var indexStyle = LetterIndexStyle.classic.rawValue
    private var classicIndex: Bool { indexStyle == LetterIndexStyle.classic.rawValue }

    /// Letters mean nothing in date order: month headers instead, and no index.
    private var showsLetters: Bool { sort != .added }

    /// What the sections depend on; a change rebuilds them.
    private var sectionsKey: String {
        "\(sort.rawValue)|\(filteredTracks.count)|\(viewModel.audioItems.first?.Id ?? "")|\(viewModel.audioItems.last?.Id ?? "")|\(viewModel.artists.count)"
    }

    private func rebuildSections() {
        let tracks = filteredTracks
        let artists = sort == .artist ? viewModel.artistNames(for: tracks) : [:]
        let sorted = sort.sorted(tracks, artists: artists)
        switch sort {
        case .name: sections = LetterIndex.sections(sorted, name: \.Name)
        case .artist: sections = LetterIndex.sections(sorted) { artists[$0.Id] ?? "" }
        case .added: sections = TrackSort.monthSections(sorted)
        }
        // Plays in the order on screen, "#" included.
        queue = sections.flatMap(\.items)
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // Play everything or shuffle, as at the top of an album.
                LibraryPlayButtons(tracks: queue) { sortMenu }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                    .albumBackdropRow()

                // Sections with their letter in both index styles. A single flat list of
                // 8.000 rows mixing letters and songs lagged badly: the List lays out
                // sections lazily, the flat ForEach it had to measure as a whole.
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { item in
                            row(for: item)
                                .albumBackdropRow()
                                .queueSwipeActions(item, viewModel: viewModel)
                        }
                    } header: {
                        Text(section.letter)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .sectionIndexLabel(showsLetters ? section.letter : nil)
                }
            }
            .listStyle(.plain)
            .systemLetterIndex(classicIndex && showsLetters)
            .letterScrubber(letters: classicIndex || !showsLetters ? [] : sections.map(\.letter)) { letter in
                // The section's first song: header rows can't be scrolled to.
                if let first = sections.first(where: { $0.letter == letter })?.items.first {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
            .contentMargins(.bottom, 170)
            #if os(iOS)
            .hidesMiniPlayerOnScroll()
            #endif
            .refreshable {
                await LibraryRefresh.shared.run { await viewModel.fetchAllLibraryData() }
            }
            .libraryRefreshBanner()
        }
        .navigationTitle("Brani")
        .task(id: sectionsKey) { rebuildSections() }
    }

    /// "Ordina per Nome / Artista / Aggiunti di recente", the third button next to Play and Shuffle.
    private var sortMenu: some View {
        Menu {
            Picker("Ordina per", selection: $sort) {
                ForEach(TrackSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            LibraryRowIcon {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ordina per \(sort.title.lowercased())")
    }

    @ViewBuilder
    private func row(for item: AudioItem) -> some View {
        let artworkURL = viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 160)
        
        HStack(spacing: 10) {
            // Only the cover and text play: the controls to the right are siblings, so
            // their taps don't start playback and the long press opens the menu.
            Button {
                viewModel.playerManager.play(item: item, in: queue)
            } label: {
                HStack(spacing: 10) {
                    CachedAsyncImage(url: artworkURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(Color.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
                    }
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.Name).font(.body).lineLimit(1)
                        Text(viewModel.artistName(for: item) ?? "Artista Sconosciuto")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Favorite button for tracks
            Button(action: {
                viewModel.toggleFavoriteTrack(item.id)
            }) {
                Image(systemName: viewModel.isTrackFavorite(item.id) ? "heart.fill" : "heart")
                    .foregroundColor(viewModel.isTrackFavorite(item.id) ? .red : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: viewModel.isTrackFavorite(item.id))
            }
            .buttonStyle(PlainButtonStyle())

            // Download
            TrackDownloadButton(item: item)
                .padding(.trailing, 4)
            
            if viewModel.currentlyPlayingItem?.id == item.id {
                // Indicate currently playing
                Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                    .foregroundColor(.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: viewModel.isPlaying)
                    .contentTransition(.symbolEffect(.replace))
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
                    viewModel.playerManager.play(item: item, in: queue)
                }
            }) {
                let isCurrent = (viewModel.currentlyPlayingItem?.id == item.id)
                let playing = viewModel.isPlaying && isCurrent
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                viewModel.playerManager.play(item: item, in: queue)
            } label: {
                Label("Riproduci", systemImage: "play.fill")
            }
            QueueMenuItems(tracks: [item])
            Divider()
            TrackNavigationMenuItems(track: item)
        }
    }
}

/// The download control of one row. It observes only its own song, and the ring is a
/// separate view: progress ticks redraw just the ring, never the list.
private struct TrackDownloadButton: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let item: AudioItem

    var body: some View {
        let state = DownloadManager.shared.itemState(for: item.Id)
        switch state.status {
        case .notDownloaded:
            Button {
                viewModel.downloadTrack(item)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        case .downloading:
            DownloadProgressRing(state: state)
                .onTapGesture {
                    viewModel.removeDownload(for: item.Id)
                }
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundColor(.accentColor)
                .contextMenu {
                    Button(role: .destructive) {
                        viewModel.removeDownload(for: item.Id)
                    } label: {
                        Label("Rimuovi download", systemImage: "trash")
                    }
                }
        }
    }
}

/// The only view that reads a song's progress.
private struct DownloadProgressRing: View {
    let state: DownloadItemState

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: 2)
                .frame(width: 18, height: 18)
            Circle()
                .trim(from: 0, to: state.progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 18, height: 18)
                .rotationEffect(.degrees(-90))
        }
        // Progress is published a few times a second: glide between the values.
        .animation(.linear(duration: 0.25), value: state.progress)
    }
}
