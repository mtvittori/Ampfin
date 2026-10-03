// NowPlayingAccessory.swift
// The mini player as iOS 26's own tab bar accessory, like Apple Music (and the Plancia
// app): a glass bar above the tabs that tucks in next to them when they minimize.

import SwiftUI

#if os(iOS)
struct NowPlayingAccessory: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let onOpen: () -> Void

    var body: some View {
        if let item = viewModel.currentlyPlayingItem {
            let compact = placement == .inline

            HStack(spacing: 10) {
                CachedAsyncImage(url: viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 120), targetSize: 36,
                    content: { $0.resizable().aspectRatio(contentMode: .fill) },
                    placeholder: { RoundedRectangle(cornerRadius: 6).fill(.quaternary) }
                )
                .id(item.AlbumId ?? item.id)
                .frame(width: compact ? 26 : 34, height: compact ? 26 : 34)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 5 : 7, style: .continuous))

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.Name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !compact, let artist = viewModel.artistName(for: item) {
                        Text(artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                Button {
                    viewModel.isPlaying ? viewModel.playerManager.pause() : viewModel.playerManager.play()
                } label: {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel(viewModel.isPlaying ? "Pausa" : "Riproduci")

                if !compact {
                    Button {
                        viewModel.playerManager.forward()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.body)
                            .frame(width: 32, height: 36)
                    }
                    .accessibilityLabel("Successivo")
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .contentShape(Rectangle())
            .onTapGesture(perform: onOpen)
            .accessibilityAction(named: "Apri il player", onOpen)
        }
    }
}

extension View {
    /// The accessory, shown only while something is loaded (hiding it needs iOS 26.1).
    @ViewBuilder
    func nowPlayingAccessory(isEnabled: Bool, onOpen: @escaping () -> Void) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: isEnabled) {
                NowPlayingAccessory(onOpen: onOpen)
            }
        } else {
            tabViewBottomAccessory {
                NowPlayingAccessory(onOpen: onOpen)
            }
        }
    }
}
#endif
