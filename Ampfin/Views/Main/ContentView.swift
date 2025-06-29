import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        if !viewModel.isLoggedIn {
            LoginView()
                .frame(minWidth: 800, minHeight: 600)
        } else {
            // Usiamo GeometryReader per creare uno sfondo unificato
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    // Livello 0: Sfondo di vetro unificato
                    // Questo sfondo sta sotto tutto e dà l'effetto desiderato.
                    Color.clear
                        .background(.ultraThinMaterial)
                        .ignoresSafeArea()

                    // Livello 1: La TabView principale
                    TabView {
                        TracksView()
                            .tabItem { Label("Brani", systemImage: "music.note.list") }
                        
                        AlbumsView()
                            .tabItem { Label("Album", systemImage: "square.stack.fill") }
                        
                        ArtistsView()
                            .tabItem { Label("Artisti", systemImage: "music.mic") }
                        
                        GenresView()
                            .tabItem { Label("Generi", systemImage: "guitars.fill") }
                    }
                    // Per rendere la TabView trasparente e far vedere lo sfondo
                    // dello ZStack, dobbiamo modificare l'aspetto della UITabBar (su iOS)
                    // o semplicemente assicurarci che le viste interne non abbiano sfondi opachi.
                    // Su macOS, il comportamento di default è già abbastanza trasparente.

                    // Livello 2: La barra del player in overlay
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
                        // Lo stile flottante è applicato qui
                        .padding(.horizontal)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.currentlyPlayingItem != nil)
            .frame(minWidth: 800, minHeight: 600)
            .task {
                if viewModel.audioItems.isEmpty {
                    await viewModel.fetchAllLibraryData()
                }
            }
        }
    }
}
