import SwiftUI

struct MusicPlayerView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    
    let item: AudioItem
    let isPlaying: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let artworkURL: URL?
    
    let onPlayPause: () -> Void
    let onBackward: () -> Void
    let onForward: () -> Void
    let onSeek: (TimeInterval) -> Void
    var artworkNamespace: Namespace.ID? = nil
    
    @ObservedObject private var colorManager = AccentColorManager.shared
    @State private var sliderValue: Double = 0
    @State private var isEditingSlider: Bool = false
    @State private var avgColor: Color = .clear

    private var playButtonTint: Color {
        colorManager.glassTintEnabled ? avgColor.opacity(colorManager.glassTintIntensity) : .accentColor
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var body: some View {
        #if os(macOS)
        macOSLayout
        #else
        if colorManager.zuneStyleEnabled {
            zuneCompactLayout
        } else {
            compactLayout
        }
        #endif
    }

    // MARK: - macOS Layout (wide horizontal bar)

    #if os(macOS)
    private var macOSLayout: some View {
        HStack(spacing: 12) {
            artworkView(size: 48)
            
            // Track info
            VStack(alignment: .leading, spacing: 2) {
                Text(item.Name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if item.isLossless {
                        losslessBadge
                    }
                    if let artist = viewModel.artistName(for: item) {
                        Text(artist)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 140, maxWidth: 200, alignment: .leading)
            
            // Time & Slider
            Text(formatTime(currentTime))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 40)
            
            seekSlider
                .frame(height: 20)
            
            Text(formatTime(duration))
                .font(.caption2.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 40)
            
            // Transport controls — plain buttons drawn straight on the capsule's own
            // glass material. Wrapping each one in its own .glass/.glassProminent style
            // layers glass on top of glass, which macOS renders as flat, opaque black
            // circles rather than translucent — only the play button gets a solid tinted
            // fill for prominence, same treatment as the full-screen player's transport row.
            HStack(spacing: 8) {
                Button(action: onBackward) {
                    Image(systemName: "backward.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(playButtonTint))
                }
                .buttonStyle(.plain)

                Button(action: onForward) {
                    Image(systemName: "forward.fill")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)

                Button(action: { viewModel.toggleRepeatMode() }) {
                    Image(systemName: viewModel.repeatMode.iconName)
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundColor(viewModel.repeatMode == .off ? .primary : .accentColor)
                .accessibilityLabel("Repeat mode")
                .help({
                    switch viewModel.repeatMode {
                    case .off: return "Repeat off"
                    case .all: return "Repeat all"
                    case .one: return "Repeat one"
                    }
                }())

                AirPlayView()
                    .frame(width: 28, height: 28)
                    .tint(.primary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 20)
        .glassEffect((colorManager.glassTintEnabled ? Glass.regular.tint(avgColor.opacity(0.8 * colorManager.glassTintIntensity)) : Glass.regular).interactive(), in: .capsule)
        .onChange(of: currentTime) {
            if !isEditingSlider {
                sliderValue = currentTime
            }
        }
        .task(id: artworkURL) {
            await loadAverageColor(url: artworkURL)
        }
    }
    #endif

    // MARK: - iOS Compact Layout

    #if os(iOS)
    private var compactLayout: some View {
        VStack(spacing: 6) {
            // Row 1: artwork + track info + transport
            HStack(spacing: 10) {
                artworkView(size: 44)
                    .playerArtwork(in: artworkNamespace)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.Name)
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if item.isLossless {
                            losslessBadge
                        }
                        if let artist = viewModel.artistName(for: item) {
                            Text(artist)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                
                Spacer()
                
                HStack(spacing: 16) {
                    Button(action: onBackward) {
                        Image(systemName: "backward.fill")
                            .font(.subheadline)
                    }
                    
                    Button(action: onPlayPause) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    
                    Button(action: onForward) {
                        Image(systemName: "forward.fill")
                            .font(.subheadline)
                    }
                }
                .buttonStyle(.plain)
            }
            
            // Row 2: interactive seek slider
            Slider(
                value: Binding(
                    get: { isEditingSlider ? sliderValue : currentTime },
                    set: { sliderValue = $0 }
                ),
                in: 0...(duration > 0 ? duration : 1),
                onEditingChanged: { editing in
                    isEditingSlider = editing
                    if !editing { onSeek(sliderValue) }
                }
            )
            .tint(.primary)
            .frame(height: 20)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        // Interactive: the bar answers the finger before it opens the full player.
        .glassEffect((colorManager.glassTintEnabled ? Glass.regular.tint(avgColor.opacity(0.8 * colorManager.glassTintIntensity)) : Glass.regular).interactive(), in: .rect(cornerRadius: 16))
        .onChange(of: currentTime) {
            if !isEditingSlider {
                sliderValue = currentTime
            }
        }
        .task(id: artworkURL) {
            await loadAverageColor(url: artworkURL)
        }
    }
    #endif

    #if os(iOS)
    /// Zune bar: flat black, square cover, lowercase Selawik, a thin accent progress line.
    private var zuneCompactLayout: some View {
        let progress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: artworkURL,
                    content: { $0.resizable().aspectRatio(contentMode: .fill) },
                    placeholder: { Rectangle().fill(.white.opacity(0.12)) }
                )
                .id(artworkURL)
                .frame(width: 48, height: 48)
                .clipped()
                .playerArtwork(in: artworkNamespace)

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.Name.lowercased())
                        .font(.zune(19, .semilight, relativeTo: .body))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text((viewModel.artistName(for: item) ?? "").lowercased())
                        .font(.zune(14, .regular, relativeTo: .caption))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Button(action: onBackward) {
                    Image(systemName: "backward.fill")
                        .font(.footnote)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Precedente")
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 38, height: 38)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .accessibilityLabel(isPlaying ? "Pausa" : "Riproduci")
                Button(action: onForward) {
                    Image(systemName: "forward.fill")
                        .font(.footnote)
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Successivo")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)

            GeometryReader { geo in
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * progress)
            }
            .frame(height: 3)
        }
        .background(Color.black.opacity(0.88))
        .environment(\.colorScheme, .dark)
    }
    #endif

    // MARK: - Shared Components

    private func artworkView(size: CGFloat) -> some View {
        CachedAsyncImage(url: artworkURL,
            content: { image in
                image.resizable().aspectRatio(contentMode: .fill)
            },
            placeholder: {
                Rectangle().fill(.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
            }
        )
        .id(artworkURL)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 40 ? 8 : 6, style: .continuous))
    }

    private var losslessBadge: some View {
        Label("FLAC", systemImage: "waveform")
            .font(.caption2)
            .foregroundColor(.blue)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.blue.opacity(0.15))
            .clipShape(Capsule())
    }

    private var seekSlider: some View {
        Slider(
            value: Binding(
                get: { isEditingSlider ? sliderValue : currentTime },
                set: { sliderValue = $0 }
            ),
            in: 0...(duration > 0 ? duration : 1),
            onEditingChanged: { editing in
                isEditingSlider = editing
                if !editing { onSeek(sliderValue) }
            }
        )
    }

    // MARK: - Average Color

    private func loadAverageColor(url: URL?) async {
        guard let url else { avgColor = .clear; return }
        let key = ImageCacheService.shared.key(for: url)

        // Try cache first (off the main thread: it may read from disk)
        let cachedColor = await Task.detached(priority: .utility) { () -> Color? in
            ImageCacheService.shared.getImage(forKey: key)?.averageColor()
        }.value
        if let cachedColor {
            avgColor = cachedColor
            return
        }

        // Image not cached yet — download it, cache, then extract color
        do {
            let (data, _) = try await JellyfinAPIService.urlSession.data(from: url)
            guard let platform = PlatformImage(data: data) else { return }
            ImageCacheService.shared.setImage(platform, forKey: key)
            if let color = platform.averageColor() {
                avgColor = color
            }
        } catch {}
    }
}
