// PlaylistPages.swift
// Playlists and mixes: the tiles for the Home, the page with all the user's playlists,
// and the song page shared by a playlist and a mix (cover, Play/Shuffle/Download, songs).

import SwiftUI

// MARK: - Covers and tiles

extension Mix.Kind {
    var tint: Color {
        switch self {
        case .daily: return .orange
        case .top: return .pink
        case .rediscover: return .purple
        case .fresh: return .green
        case .discover: return .teal
        case .genre: return .indigo
        }
    }

    var systemImage: String {
        switch self {
        case .daily: return "sun.max.fill"
        case .top: return "flame.fill"
        case .rediscover: return "clock.arrow.circlepath"
        case .fresh: return "sparkles"
        case .discover: return "safari.fill"
        case .genre: return "guitars.fill"
        }
    }
}

/// Four album covers in a square, as Apple Music shows a playlist without its own picture.
struct CoverGrid: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let albumIds: [String]
    var size: CGFloat = 160

    var body: some View {
        let ids = albumIds.count >= 4 ? Array(albumIds.prefix(4)) : Array(albumIds.prefix(1))
        let columns = ids.count == 4 ? 2 : 1
        let side = size / CGFloat(columns)
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(side), spacing: 0), count: columns), spacing: 0) {
            ForEach(ids, id: \.self) { id in
                CachedAsyncImage(url: viewModel.artworkURL(for: id, size: Int(side * 2)), targetSize: side,
                    content: { $0.resizable().aspectRatio(contentMode: .fill) },
                    placeholder: { Rectangle().fill(.quaternary) })
                    .frame(width: side, height: side)
                    .clipped()
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary)
    }
}

/// A mix on the Home: its covers with a band of its color and the title on top.
struct MixCard: View {
    let mix: Mix
    var size: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CoverGrid(albumIds: mix.coverAlbumIds, size: size)
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(colors: [.clear, mix.kind.tint.opacity(0.95)],
                                   startPoint: .center, endPoint: .bottom)
                        .overlay(alignment: .bottomLeading) {
                            Label(mix.title, systemImage: mix.kind.systemImage)
                                .font(.headline)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .padding(10)
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(mix.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(width: size, alignment: .leading)
    }
}

/// A Jellyfin playlist: the server's picture for it (a collage of its albums), name, songs.
struct PlaylistTile: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let playlist: PlaylistItem
    var size: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            CachedAsyncImage(url: viewModel.artworkURL(for: playlist.Id, size: 400), targetSize: size,
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                        .overlay(Image(systemName: "music.note.list").font(.largeTitle).foregroundStyle(.secondary))
                })
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(playlist.Name.replacingOccurrences(of: "_", with: " "))
                .font(.subheadline)
                .lineLimit(1)
            if let count = playlist.songCount {
                Text(count == 1 ? "1 brano" : "\(count) brani")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, alignment: .leading)
    }
}

// MARK: - Pages

/// All the user's playlists, and a new one.
struct PlaylistsPage: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var store = MixStore.shared

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        ScrollView {
            if store.playlistsLoaded && store.userPlaylists.isEmpty {
                ContentUnavailableView("Nessuna playlist", systemImage: "music.note.list",
                    description: Text("Creane una qui, o dal menu di un brano con \"Aggiungi a playlist\"."))
                    .padding(.top, 60)
            }
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(store.userPlaylists) { playlist in
                    NavigationLink {
                        PlaylistDetailPage(playlist: playlist)
                    } label: {
                        PlaylistTile(playlist: playlist, size: 165)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(16)
            .padding(.bottom, 150)
        }
        .navigationTitle("Playlist")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.pendingNewPlaylist = []
                } label: {
                    Label("Nuova playlist", systemImage: "plus")
                }
            }
        }
        .refreshable { await store.refreshPlaylists(viewModel: viewModel) }
        .task { await store.refreshPlaylists(viewModel: viewModel) }
    }
}

/// A Jellyfin playlist's songs; songs can be taken out of it, and it can be deleted.
struct PlaylistDetailPage: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Environment(\.dismiss) private var dismiss
    let playlist: PlaylistItem

    @State private var tracks: [AudioItem] = []
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        TrackCollectionPage(
            title: playlist.Name.replacingOccurrences(of: "_", with: " "),
            subtitle: loaded ? (tracks.count == 1 ? "1 brano" : "\(tracks.count) brani") : "",
            tracks: tracks,
            onRemove: playlist.isServerMix ? nil : { track in
                Task {
                    if await MixStore.shared.remove(track, from: playlist, viewModel: viewModel) {
                        withAnimation { tracks.removeAll { $0.PlaylistItemId == track.PlaylistItemId } }
                    }
                }
            },
            cover: {
                CachedAsyncImage(url: viewModel.artworkURL(for: playlist.Id, size: 600), targetSize: 220,
                    content: { $0.resizable().aspectRatio(contentMode: .fill) },
                    placeholder: { CoverGrid(albumIds: tracks.compactMap(\.AlbumId), size: 220) })
            },
            menu: {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Elimina playlist", systemImage: "trash")
                }
            }
        )
        .overlay {
            if !loaded { ProgressView() }
        }
        .confirmationDialog("Eliminare \"\(playlist.Name)\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina playlist", role: .destructive) {
                Task {
                    await MixStore.shared.delete(playlist, viewModel: viewModel)
                    dismiss()
                }
            }
        } message: {
            Text("La playlist sparisce da Jellyfin per tutte le app. I brani restano nella libreria.")
        }
        .task {
            tracks = (try? await viewModel.apiService?.fetchPlaylistItems(playlistId: playlist.Id)) ?? []
            loaded = true
        }
    }
}

/// An Ampfin mix's songs; it can be saved as a real playlist on Jellyfin.
struct MixDetailPage: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let mix: Mix

    var body: some View {
        TrackCollectionPage(
            title: mix.title,
            subtitle: mix.subtitle,
            tracks: mix.tracks,
            onRemove: nil,
            cover: { CoverGrid(albumIds: mix.coverAlbumIds, size: 220) },
            menu: {
                Button {
                    let date = Date().formatted(.dateTime.day().month(.abbreviated))
                    MixStore.shared.createPlaylist(named: "\(mix.title) · \(date)", with: mix.tracks, viewModel: viewModel)
                } label: {
                    Label("Salva come playlist", systemImage: "square.and.arrow.down")
                }
            }
        )
    }
}

/// Cover, title, Play / Shuffle / Download, then the songs.
struct TrackCollectionPage<Cover: View, MenuItems: View>: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let title: String
    let subtitle: String
    let tracks: [AudioItem]
    let onRemove: ((AudioItem) -> Void)?
    @ViewBuilder var cover: () -> Cover
    @ViewBuilder var menu: () -> MenuItems

    var body: some View {
        List {
            VStack(spacing: 10) {
                cover()
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .entrance(.rise)

            LibraryPlayButtons(tracks: tracks) { DownloadAllButton(tracks: tracks) }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 10, trailing: 16))

            ForEach(tracks, id: \.rowId) { track in
                CollectionTrackRow(track: track, queue: tracks, onRemove: onRemove)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .queueSwipeActions(track, viewModel: viewModel)
            }
        }
        .listStyle(.plain)
        .contentMargins(.bottom, 170)
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    AddToPlaylistMenu(tracks: tracks)
                    menu()
                } label: {
                    Label("Altro", systemImage: "ellipsis")
                }
            }
        }
    }
}

private extension AudioItem {
    /// A playlist can hold the same song twice: its entry id tells them apart.
    var rowId: String { PlaylistItemId ?? Id }
}

/// A song in a playlist or mix: cover, title, artist, downloaded mark, the wave while it plays.
struct CollectionTrackRow: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared
    let track: AudioItem
    let queue: [AudioItem]
    let onRemove: ((AudioItem) -> Void)?

    private var isCurrent: Bool { viewModel.currentlyPlayingItem?.id == track.id }

    var body: some View {
        // A Button instead of onTapGesture: the tap no longer competes with the context menu's long press.
        Button {
            viewModel.playerManager.play(item: track, in: queue)
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 160), targetSize: 52,
                    content: { $0.resizable().aspectRatio(contentMode: .fill) },
                    placeholder: { RoundedRectangle(cornerRadius: 8).fill(.quaternary) })
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.Name)
                        .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(viewModel.artistName(for: track) ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

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
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                viewModel.playerManager.play(item: track, in: queue)
            } label: {
                Label("Riproduci", systemImage: "play.fill")
            }
            QueueMenuItems(tracks: [track])
            Divider()
            TrackNavigationMenuItems(track: track)
            if let onRemove {
                Divider()
                Button(role: .destructive) {
                    onRemove(track)
                } label: {
                    Label("Rimuovi dalla playlist", systemImage: "minus.circle")
                }
            }
        }
    }
}
