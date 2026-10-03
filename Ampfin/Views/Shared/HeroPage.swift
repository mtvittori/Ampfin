// HeroPage.swift
// Album and artist pages in the style of Apple Music on iOS 26: the cover (or the
// artist's photo) runs edge to edge under the status bar and fades into a page
// colored like the image's bottom edge; title, subtitle and details sit centered on
// the fade, then shuffle / Play / favorite, then the content. Text turns black on
// light pages and white on dark ones.

import SwiftUI

/// The page color taken from the image, and the text color that reads on it.
struct HeroPalette: Equatable {
    var background: Color
    var isLight: Bool

    var foreground: Color { isLight ? .black : .white }
    var secondary: Color { foreground.opacity(0.62) }

    static let neutral = HeroPalette(background: Color(white: 0.14), isLight: false)

    init(background: Color, isLight: Bool) {
        self.background = background
        self.isLight = isLight
    }

    /// Average of the image's bottom rows, so the fade has no visible seam.
    init?(image: PlatformImage) {
        guard let cgImage = image.cgImage else { return nil }
        let size = 12
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        // The bitmap's first row is the top of the image: the last two are the bottom edge.
        var r = 0.0, g = 0.0, b = 0.0
        for row in (size - 2)..<size {
            for column in 0..<size {
                let i = (row * size + column) * 4
                r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2])
            }
        }
        let n = Double(2 * size) * 255
        r /= n; g /= n; b /= n
        background = Color(red: r, green: g, blue: b)
        isLight = 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.62
    }
}

/// The scrolling page: image header, centered titles, controls, content.
struct HeroPage<Controls: View, Content: View>: View {
    let imageURLs: [URL]
    let title: String
    let subtitle: String?
    /// Opens the subtitle's page (the artist, from an album).
    var subtitleDestination: AnyView? = nil
    let details: String
    @ViewBuilder let controls: (HeroPalette) -> Controls
    @ViewBuilder let content: (HeroPalette) -> Content

    @State private var image: PlatformImage?
    @State private var palette = HeroPalette.neutral

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ScrollView {
                VStack(spacing: 0) {
                    header(width: width)
                    controls(palette)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 22)
                        .entrance(.rise, delay: 0.12)
                    content(palette)
                }
                .padding(.bottom, 170)
            }
            .ignoresSafeArea(edges: .top)
            #if os(iOS)
            .hidesMiniPlayerOnScroll()
            #endif
        }
        .background(palette.background.ignoresSafeArea())
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
        .tint(palette.foreground)
        .animation(.easeInOut(duration: 0.5), value: palette)
        .task(id: imageURLs) {
            guard let loaded = await ZuneImageLoader.shared.firstImage(from: imageURLs) else { return }
            image = loaded
            if let colors = HeroPalette(image: loaded) { palette = colors }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }

    private func header(width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            Group {
                if let image {
                    Image(platformImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .transition(.opacity)
                } else {
                    palette.background
                }
            }
            .frame(width: width, height: width)
            .clipped()
            // Pulling down past the top stretches the image instead of showing a gap.
            .visualEffect { content, proxy in
                let pull = max(proxy.frame(in: .scrollView).minY, 0)
                return content
                    .scaleEffect(1 + pull / max(width, 1), anchor: .bottom)
            }

            LinearGradient(stops: [
                .init(color: palette.background.opacity(0), location: 0),
                .init(color: palette.background.opacity(0.75), location: 0.55),
                .init(color: palette.background, location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .frame(height: width * 0.5)

            VStack(spacing: 3) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(palette.foreground)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    if let subtitleDestination {
                        NavigationLink(destination: subtitleDestination) {
                            Text(subtitle)
                                .font(.title3)
                                .foregroundStyle(palette.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(subtitle)
                            .font(.title3)
                            .foregroundStyle(palette.secondary)
                    }
                }
                if !details.isEmpty {
                    Text(details)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.secondary)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 4)
            .entrance(.rise, delay: 0.05)
        }
        .frame(width: width, height: width)
    }
}

/// Shuffle · Play · favorite, in glass. While this album or artist is playing, shuffle
/// melts into the Play capsule, which becomes "In riproduzione" with a moving wave
/// (Liquid Glass morph); tapping it pauses and resumes.
struct HeroPlayControls: View {
    let palette: HeroPalette
    let isCurrent: Bool
    let isPlaying: Bool
    let isFavorite: Bool?
    let onPlay: () -> Void
    let onShuffle: () -> Void
    let onTogglePause: () -> Void
    let onFavorite: () -> Void

    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(spacing: 14) {
                if !isCurrent {
                    circle("shuffle", label: "Casuale", action: onShuffle)
                        .glassEffectID("shuffle", in: glass)
                }

                Button(action: isCurrent ? onTogglePause : onPlay) {
                    Label(isCurrent ? (isPlaying ? "In riproduzione" : "In pausa") : "Play",
                          systemImage: isCurrent ? (isPlaying ? "waveform" : "play.fill") : "play.fill")
                        .font(.body.weight(.semibold))
                        .symbolEffect(.variableColor.iterative, isActive: isCurrent && isPlaying)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(palette.isLight ? Color.white : Color.black)
                        .frame(minWidth: 116)
                        .padding(.horizontal, 18)
                        .frame(height: 46)
                        .glassEffect(.regular.tint(palette.foreground.opacity(0.92)).interactive(), in: .capsule)
                        .glassEffectID("play", in: glass)
                }
                .buttonStyle(.plain)
                .accessibilityHint(isCurrent ? (isPlaying ? "Mette in pausa" : "Riprende") : "")

                if let isFavorite {
                    circle(isFavorite ? "heart.fill" : "heart",
                           label: isFavorite ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                           action: onFavorite)
                        .symbolEffect(.bounce, value: isFavorite)
                        .glassEffectID("favorite", in: glass)
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.bouncy(duration: 0.45), value: isCurrent)
            .animation(.bouncy(duration: 0.45), value: isPlaying)
        }
    }

    private func circle(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.foreground)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 46, height: 46)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A song row on a hero page: number, title (and a second line when useful), the
/// moving wave when it plays, the length; long press for favorite and download.
struct HeroTrackRow: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared

    let track: AudioItem
    let number: Int?
    let detail: String?
    let queue: [AudioItem]
    let palette: HeroPalette
    var onInfo: ((AudioItem) -> Void)?

    private var isCurrent: Bool { viewModel.currentlyPlayingItem?.id == track.id }

    var body: some View {
        Button {
            viewModel.playerManager.play(item: track, in: queue)
        } label: {
            HStack(spacing: 14) {
                if let number {
                    Group {
                        if isCurrent {
                            Image(systemName: viewModel.isPlaying ? "waveform" : "pause.fill")
                                .symbolEffect(.variableColor.iterative, isActive: viewModel.isPlaying)
                                .font(.footnote.weight(.semibold))
                        } else {
                            Text("\(number)")
                                .font(.callout.monospacedDigit())
                        }
                    }
                    .foregroundStyle(palette.secondary)
                    .frame(width: 24)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(track.Name)
                            .font(.body)
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        if viewModel.isTrackFavorite(track.id) {
                            Image(systemName: "heart.fill")
                                .font(.caption2)
                                .foregroundStyle(palette.secondary)
                        }
                        if downloadManager.isDownloaded(track.Id) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(palette.secondary)
                        }
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(palette.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let duration = track.duration {
                    Text(ZuneFormat.time(duration))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(palette.secondary)
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.foreground.opacity(0.12))
                .frame(height: 0.5)
                .padding(.leading, number == nil ? 0 : 38)
        }
        .contextMenu {
            Button {
                viewModel.playerManager.play(item: track, in: queue)
            } label: {
                Label("Riproduci", systemImage: "play.fill")
            }
            Button {
                viewModel.toggleFavoriteTrack(track.id)
            } label: {
                Label(viewModel.isTrackFavorite(track.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                      systemImage: viewModel.isTrackFavorite(track.id) ? "heart.slash" : "heart")
            }
            if downloadManager.isDownloaded(track.Id) {
                Button(role: .destructive) {
                    viewModel.removeDownload(for: track.Id)
                } label: {
                    Label("Rimuovi download", systemImage: "trash")
                }
            } else {
                Button {
                    viewModel.downloadTrack(track)
                } label: {
                    Label("Scarica", systemImage: "arrow.down.circle")
                }
            }
            if let onInfo {
                Divider()
                Button {
                    onInfo(track)
                } label: {
                    Label("Dettagli brano", systemImage: "info.circle")
                }
            }
        }
    }
}
