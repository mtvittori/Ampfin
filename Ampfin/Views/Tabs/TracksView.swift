import SwiftUI

struct TracksView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var searchText = ""
    /// Sorted and grouped in the background and kept across tab switches (see TrackSectionsStore):
    /// 9.700 songs are too many to sort on the main thread at every visit.
    @ObservedObject private var store = TrackSectionsStore.shared

    @AppStorage("tracksSort") private var sort: TrackSort = .name
    @AppStorage(LetterIndexStyle.storageKey) private var indexStyle = LetterIndexStyle.classic.rawValue
    private var classicIndex: Bool { indexStyle == LetterIndexStyle.classic.rawValue }

    private var query: String {
        // On iPhone the search field filters only the Cerca tab; on the Mac the toolbar
        // search filters the section in view.
        #if os(macOS)
        return viewModel.globalSearchQuery.isEmpty ? searchText : viewModel.globalSearchQuery
        #else
        return searchText
        #endif
    }

    var body: some View {
        let key = TrackSectionsStore.Key(library: viewModel.libraryRevision, sort: sort, query: query)
        // The list for this sort when ready, else the previous one (never a blank page).
        let result = store.result(for: key)
        ScrollViewReader { proxy in
            List {
                // Play everything or shuffle, as at the top of an album.
                LibraryPlayButtons(tracks: result.queue) { sortMenu }
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                    .albumBackdropRow()

                // Sections with their letter in both index styles. A single flat list of
                // 8.000 rows mixing letters and songs lagged badly: the List lays out
                // sections lazily, the flat ForEach it had to measure as a whole.
                TrackSectionsContent(viewModel: viewModel, result: result)
            }
            .listStyle(.plain)
            .systemLetterIndex(classicIndex && result.showsLetters)
            .letterScrubber(letters: classicIndex || !result.showsLetters ? [] : result.sections.map(\.letter)) { letter in
                // The section's first song: header rows can't be scrolled to.
                if let first = result.sections.first(where: { $0.letter == letter })?.items.first {
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
        // Back on the tab with nothing changed this finds the list ready and does nothing.
        .task(id: key) {
            store.ensure(key, tracks: viewModel.audioItems, names: viewModel.artistNameLookup)
        }
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
}

/// The letter sections and their rows. Its own view, with only values and a reference as
/// properties: SwiftUI skips its body (and the ForEach closure over every song) when the
/// list hasn't changed, instead of rebuilding 9.700 rows at each view model update.
private struct TrackSectionsContent: View {
    /// Not observed on purpose: the rows observe what they show.
    let viewModel: JellyfinViewModel
    let result: TrackSectionsResult
    @Environment(\.albumBackdropActive) private var backdropActive

    var body: some View {
        ForEach(result.sections) { section in
            Section {
                ForEach(section.items) { item in
                    // Only this row, a struct built here and evaluated when it scrolls in: it
                    // used to be a method of TracksView whose whole view tree (cover, buttons,
                    // menu) was assembled inline for every song at every redraw. No conditional
                    // modifier around it either, so the list can count the rows without
                    // resolving them.
                    TrackListRow(item: item, list: result)
                        .equatable()
                        .listRowBackground(backdropActive ? Color.clear : nil)
                        .queueSwipeActions(item, viewModel: viewModel)
                }
            } header: {
                Text(section.letter)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .sectionIndexLabel(result.showsLetters ? section.letter : nil)
        }
    }
}

/// A song row of Brani. Equatable on what it shows (the list it plays from by identity), so
/// a parent redraw doesn't re-evaluate rows that haven't changed.
private struct TrackListRow: View, Equatable {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let item: AudioItem
    /// The queue a tap plays: the whole list in screen order.
    let list: TrackSectionsResult

    static func == (lhs: TrackListRow, rhs: TrackListRow) -> Bool {
        lhs.item.Id == rhs.item.Id && lhs.item.Name == rhs.item.Name && lhs.list === rhs.list
    }

    var body: some View {
        let isCurrent = viewModel.currentlyPlayingItem?.id == item.id
        let isFavorite = viewModel.isTrackFavorite(item.id)
        let artworkURL = viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 160)

        HStack(spacing: 10) {
            // Only the cover and text play: the controls to the right are siblings, so
            // their taps don't start playback and the long press opens the menu.
            Button {
                viewModel.playerManager.play(item: item, in: list.queue)
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
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundColor(isFavorite ? .red : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: isFavorite)
            }
            .buttonStyle(PlainButtonStyle())

            // Download
            TrackDownloadButton(item: item)
                .padding(.trailing, 4)

            if isCurrent {
                // Indicate currently playing
                Image(systemName: viewModel.isPlaying ? "waveform" : "pause.circle")
                    .foregroundColor(.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: viewModel.isPlaying)
                    .contentTransition(.symbolEffect(.replace))
            }

            Button(action: {
                if isCurrent {
                    if viewModel.isPlaying {
                        viewModel.playerManager.pause()
                    } else {
                        viewModel.playerManager.play()
                    }
                } else {
                    viewModel.playerManager.play(item: item, in: list.queue)
                }
            }) {
                let playing = viewModel.isPlaying && isCurrent
                // A material disc, not `.glass`: a glass layer per row cost more than it showed.
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        // The menu's content is built when it opens, nothing of it is worked out here.
        .contextMenu {
            Button {
                viewModel.playerManager.play(item: item, in: list.queue)
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
