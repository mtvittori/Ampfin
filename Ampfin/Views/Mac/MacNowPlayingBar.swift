// MacNowPlayingBar.swift
// The playback bar as Music shows it on the Mac: a glass capsule floating at the bottom of
// the window. Shuffle / previous / play / next / repeat on the left, the cover with title,
// artist and a thin progress line in the middle, lyrics, queue, AirPlay and volume on the right.

#if os(macOS)
import SwiftUI

struct MacPlaybackBar: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject var player: AudioPlayerManager
    @Binding var showPanel: Bool
    @Binding var panelTab: String

    @State private var showVolume = false

    private var hasItem: Bool { player.currentlyPlayingItem != nil }

    var body: some View {
        HStack(spacing: 16) {
            transport
            center
                .frame(maxWidth: .infinity)
            accessories
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }

    // MARK: - Left

    private var transport: some View {
        HStack(spacing: 14) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(player.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help("Casuale")

            Button { player.backward() } label: { Image(systemName: "backward.fill").font(.system(size: 15)) }
                .help("Precedente")

            Button { player.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 21))
                    .frame(width: 24)
            }
            .help(viewModel.isPlaying ? "Pausa" : "Riproduci")

            Button { player.forward() } label: { Image(systemName: "forward.fill").font(.system(size: 15)) }
                .help("Successivo")

            Button { viewModel.toggleRepeatMode() } label: {
                Image(systemName: viewModel.repeatMode.iconName).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(viewModel.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .help("Ripeti")
        }
        .buttonStyle(.plain)
        .disabled(!hasItem)
    }

    // MARK: - Middle

    @ViewBuilder
    private var center: some View {
        if let item = player.currentlyPlayingItem {
            HStack(spacing: 10) {
                MacCover(itemId: item.AlbumId ?? item.id, size: 38, radius: 5, imageSize: 100)
                VStack(spacing: 1) {
                    Text(item.Name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text([viewModel.artistName(for: item), item.Album].compactMap { $0 }.joined(separator: " — "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    ClockReader(clock: viewModel.clock) { time in
                        HStack(spacing: 6) {
                            Text(MacFormat.clock(time)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                            MacScrubber(value: time, total: item.duration ?? 0) { viewModel.playerManager.seek(to: $0) }
                            Text("-" + MacFormat.clock(max((item.duration ?? 0) - time, 0)))
                                .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                Button { viewModel.toggleFavoriteTrack(item.id) } label: {
                    Image(systemName: viewModel.isTrackFavorite(item.id) ? "heart.fill" : "heart")
                        .foregroundStyle(viewModel.isTrackFavorite(item.id) ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .help("Preferito")
            }
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Right

    private var accessories: some View {
        HStack(spacing: 14) {
            panelButton("lyrics", systemImage: "quote.bubble", help: "Testi")
            panelButton("queue", systemImage: "list.bullet", help: "Coda")

            AirPlayView()
                .frame(width: 24, height: 24)
                .help("AirPlay")

            Button { showVolume.toggle() } label: {
                Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .help("Volume")
            .popover(isPresented: $showVolume, arrowEdge: .top) {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }), in: 0...1)
                        .frame(width: 150)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
    }

    /// Opens the right-hand panel on a tab, or closes it when that tab is already showing.
    private func panelButton(_ tab: String, systemImage: String, help: String) -> some View {
        let active = showPanel && panelTab == tab
        return Button {
            if active {
                showPanel = false
            } else {
                panelTab = tab
                showPanel = true
            }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .symbolVariant(active ? .fill : .none)
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A thin progress line that thickens under the pointer; click or drag to seek.
struct MacScrubber: View {
    let value: TimeInterval
    let total: TimeInterval
    let onSeek: (TimeInterval) -> Void

    @State private var hovering = false
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { geo in
            let fraction = dragging ?? (total > 0 ? min(max(value / total, 0), 1) : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.secondary).frame(width: geo.size.width * fraction)
            }
            .frame(height: hovering || dragging != nil ? 5 : 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { dragging = min(max($0.location.x / geo.size.width, 0), 1) }
                    .onEnded {
                        let f = min(max($0.location.x / geo.size.width, 0), 1)
                        dragging = nil
                        onSeek(f * total)
                    }
            )
            .onHover { hovering = $0 }
        }
        .frame(height: 10)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
#endif
