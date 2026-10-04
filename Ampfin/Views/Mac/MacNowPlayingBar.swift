// MacNowPlayingBar.swift
// The toolbar: shuffle / previous / play / next / repeat on the left, and in the middle
// the lozenge with the cover, title, artist and a thin progress line you can click to seek.

#if os(macOS)
import SwiftUI

struct MacTransportControls: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject var player: AudioPlayerManager

    var body: some View {
        HStack(spacing: 2) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(player.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .help("Casuale")
            .disabled(player.currentlyPlayingItem == nil)

            Button { player.backward() } label: { Image(systemName: "backward.fill") }
                .help("Precedente")
                .disabled(player.currentlyPlayingItem == nil)

            Button { player.togglePlayPause() } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 22)
            }
            .help(viewModel.isPlaying ? "Pausa" : "Riproduci")
            .disabled(player.currentlyPlayingItem == nil)

            Button { player.forward() } label: { Image(systemName: "forward.fill") }
                .help("Successivo")
                .disabled(player.currentlyPlayingItem == nil)

            Button { viewModel.toggleRepeatMode() } label: {
                Image(systemName: viewModel.repeatMode.iconName)
                    .foregroundStyle(viewModel.repeatMode == .off ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            }
            .help("Ripeti")
        }
    }
}

struct MacNowPlayingBar: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    var body: some View {
        Group {
            if let item = viewModel.currentlyPlayingItem {
                HStack(spacing: 10) {
                    MacCover(itemId: item.AlbumId ?? item.id, size: 38, radius: 4, imageSize: 100)

                    VStack(spacing: 1) {
                        Text(item.Name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text([viewModel.artistName(for: item), item.Album].compactMap { $0 }.joined(separator: " — "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
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

                    Button {
                        viewModel.toggleFavoriteTrack(item.id)
                    } label: {
                        Image(systemName: viewModel.isTrackFavorite(item.id) ? "heart.fill" : "heart")
                            .foregroundStyle(viewModel.isTrackFavorite(item.id) ? AnyShapeStyle(.pink) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .help("Preferito")
                }
                .padding(.horizontal, 8)
            } else {
                Text("Ampfin")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 240, idealWidth: 420, maxWidth: 520)
        .frame(height: 38)
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
