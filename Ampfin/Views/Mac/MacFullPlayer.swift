// MacFullPlayer.swift
// Now Playing over the whole window, opened from the playback bar as on iPhone: the page
// takes the cover's color, the big cover and the controls on the left, lyrics or the queue
// on the right. Esc or the chevron closes it.

#if os(macOS)
import SwiftUI

struct MacFullPlayer: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Environment(MacPlayerState.self) private var state
    @ObservedObject var player: AudioPlayerManager

    @AppStorage("macFullPlayerTab") private var tab = MacSidePanel.Tab.lyrics.rawValue

    var body: some View {
        if let item = player.currentlyPlayingItem {
            MacTintedPage(imageURLs: [viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 800)].compactMap { $0 }) { _ in
                HStack(alignment: .center, spacing: 56) {
                    nowPlaying(item)
                        .frame(maxWidth: 460)
                    MacSidePanel(tab: $tab)
                        .frame(maxWidth: 520, maxHeight: .infinity)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
                .padding(.horizontal, 56)
                .padding(.top, 56)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Button { close() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .keyboardShortcut(.cancelAction)
                    .help("Chiudi")
                    .padding(20)
                }
            }
            .onExitCommand { close() }
        }
    }

    private func close() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) { state.showFullPlayer = false }
    }

    private func nowPlaying(_ item: AudioItem) -> some View {
        VStack(spacing: 22) {
            MacCover(itemId: item.AlbumId ?? item.id, radius: 14, imageSize: 1000)
                .frame(maxWidth: 420)

            VStack(spacing: 4) {
                Text(item.Name).font(.title2.weight(.bold)).lineLimit(2).multilineTextAlignment(.center)
                Text([viewModel.artistName(for: item), item.Album].compactMap { $0 }.joined(separator: " — "))
                    .font(.title3).foregroundStyle(.secondary).lineLimit(1)
            }

            ClockReader(clock: viewModel.clock) { time in
                VStack(spacing: 4) {
                    MacScrubber(value: time, total: item.duration ?? 0) { player.seek(to: $0) }
                    HStack {
                        Text(MacFormat.clock(time))
                        Spacer()
                        Text("-" + MacFormat.clock(max((item.duration ?? 0) - time, 0)))
                    }
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 34) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(player.isShuffled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                Button { player.backward() } label: { Image(systemName: "backward.fill").font(.system(size: 26)) }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 38)).frame(width: 44)
                }
                Button { player.forward() } label: { Image(systemName: "forward.fill").font(.system(size: 26)) }
                Button { viewModel.toggleRepeatMode() } label: {
                    Image(systemName: viewModel.repeatMode.iconName).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(viewModel.repeatMode == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 18) {
                MacVolumeSlider(player: player)
                AirPlayView().frame(width: 26, height: 26)
            }
        }
    }
}
#endif
