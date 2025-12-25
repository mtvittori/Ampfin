import SwiftUI
import Cocoa

struct ContentView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    // Sidebar selection
    enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
        case home, tracks, albums, artists, genres, playlists, favorites

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "Home"
            case .tracks: return "Brani"
            case .albums: return "Album"
            case .artists: return "Artisti"
            case .genres: return "Generi"
            case .playlists: return "Playlist"
            case .favorites: return "Preferiti"
            }
        }

        var systemImage: String {
            switch self {
            case .home: return "house"
            case .tracks: return "music.note.list"
            case .albums: return "square.stack.fill"
            case .artists: return "music.mic"
            case .genres: return "guitars.fill"
            case .playlists: return "music.note.list"
            case .favorites: return "heart.fill"
            }
        }
    }

    @State private var selectedSidebar: SidebarItem? = .home
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if !viewModel.isLoggedIn {
            LoginView()
                .frame(minWidth: 800, minHeight: 600)
                .onAppear {
                    print("[ContentView] Showing LoginView (user NOT logged in)")
                }
        } else {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    Color.clear
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()

                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        // Sidebar
                        List(selection: $selectedSidebar) {
                            ForEach(SidebarItem.allCases) { item in
                                Label(item.title, systemImage: item.systemImage)
                                    .tag(item)
                                    .onTapGesture {
                                        selectedSidebar = item
                                    }
                            }
                        }
                        .listStyle(.sidebar)
                        .frame(minWidth: 160)
                    } detail: {
                        // Detail column — show the selected view
                        Group {
                            switch selectedSidebar {
                            case .home, .none:
                                HomeView()
                            case .tracks:
                                TracksView()
                            case .albums:
                                AlbumsView()
                            case .artists:
                                ArtistsView()
                            case .genres:
                                GenresView()
                            case .playlists:
                                GeneratedPlaylistsView()
                            case .favorites:
                                FavoritesView()
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(minWidth: 800, minHeight: 600)

                    // Player overlay (unchanged)
                    if let playingItem = viewModel.currentlyPlayingItem {
                        MusicPlayerView(
                            item: playingItem,
                            isPlaying: viewModel.isPlaying,
                            currentTime: viewModel.currentTime,
                            duration: playingItem.duration ?? 0,
                            artworkURL: viewModel.artworkURL(for: playingItem.AlbumId ?? playingItem.id, size: 100),
                            onPlayPause: { viewModel.playerManager.togglePlayPause() },
                            onBackward: { viewModel.playerManager.backward() },
                            onForward: { viewModel.playerManager.forward() },
                            onSeek: { time in viewModel.playerManager.seek(to: time) }
                        )
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.currentlyPlayingItem != nil)
            .frame(minWidth: 800, minHeight: 600)
            .task {
                print("[ContentView] .task triggered, audioItems count = \(viewModel.audioItems.count)")
                if viewModel.audioItems.isEmpty {
                    print("[ContentView] audioItems is empty, fetching library data...")
                    await viewModel.fetchAllLibraryData()
                    print("[ContentView] fetchAllLibraryData completed, audioItems count = \(viewModel.audioItems.count)")
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 16)

                            ZStack {
                                HStack(spacing: 8) {
                                    TextField("Cerca...", text: $viewModel.globalSearchQuery)
                                        .textFieldStyle(.plain)
                                        .submitLabel(.search)
                                        .padding(.vertical, 6)
                                        .padding(.leading, 6)

                                    if !viewModel.globalSearchQuery.isEmpty {
                                        Button(action: { viewModel.globalSearchQuery = "" }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .padding(.trailing, 6)
                                    }
                                }
                                .padding(.horizontal, 6)
                            }
                            .frame(width: 360, height: 34)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                ToolbarItem(placement: .automatic) {
                    Button {
                        print("[ContentView] Toolbar refresh tapped")
                        Task {
                            await viewModel.fetchAllLibraryData()
                            print("[ContentView] Toolbar fetch completed, audioItems count = \(viewModel.audioItems.count)")
                        }
                    } label: {
                        Label("Aggiorna", systemImage: "arrow.clockwise")
                    }
                }

                ToolbarItem(placement: .automatic) {
                    Button(action: { viewModel.logout() }) {
                        Label("Logout", systemImage: "person.crop.circle.badge.xmark")
                    }
                }
            }
        }
    }

    private func toggleSidebarVisibility() {
        switch columnVisibility {
        case .all:
            columnVisibility = .detailOnly
        case .detailOnly:
            columnVisibility = .all
        case .automatic:
            columnVisibility = .all
        default:
            columnVisibility = .all
        }
    }
}
