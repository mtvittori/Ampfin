// ZuneStyle.swift
// Building blocks for the Zune look: the artist photo panning slowly behind
// everything, and huge lowercase Segoe-like type that runs off the screen edge.

import SwiftUI
import CoreText

// MARK: - Pivot environment

extension EnvironmentValues {
    /// Height of the Windows Phone pivot header above the page, 0 outside the pivot.
    /// Pages then skip their own giant title and stretch their photo up behind the header.
    @Entry var zunePivotHeaderHeight: CGFloat = 0
    /// True for pivot pages that are off screen, so their photo stops panning.
    @Entry var zuneBackdropPaused: Bool = false
    /// How far above the page the pivot wants the photo to reach (header plus bars).
    @Entry var zuneBackdropReach: CGFloat = 0
}

// MARK: - Font

/// Selawik is Microsoft's open-source (OFL) stand-in for Segoe UI, the Zune typeface.
/// Registered at runtime so no Info.plist change is needed on either platform.
enum ZuneFont {
    enum Weight: String {
        case light = "Selawik-Light"
        case semilight = "Selawik-Semilight"
        case regular = "Selawik-Regular"
        case semibold = "Selawik-Semibold"
    }

    fileprivate static let registered: Bool = {
        for weight in [Weight.light, .semilight, .regular, .semibold] {
            let url = Bundle.main.url(forResource: weight.rawValue, withExtension: "ttf")
                ?? Bundle.main.url(forResource: weight.rawValue, withExtension: "ttf", subdirectory: "Fonts")
            if let url {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        return true
    }()
}

extension Font {
    static func zune(_ size: CGFloat, _ weight: ZuneFont.Weight = .light, relativeTo style: Font.TextStyle = .body) -> Font {
        _ = ZuneFont.registered
        return .custom(weight.rawValue, size: size, relativeTo: style)
    }
}

// MARK: - Oversized text

/// Lowercase headline wider than the screen: laid out at its natural width and left
/// to run past the trailing edge, like the Zune pivot headers.
struct ZuneOverflowText: View {
    let text: String
    var size: CGFloat = 72
    var weight: ZuneFont.Weight = .light
    var color: Color = .white

    var body: some View {
        Text(text.lowercased())
            .font(.zune(size, weight, relativeTo: .largeTitle))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(text)
    }
}

// MARK: - Image loading

/// Loads the first of several candidate images that the server actually has.
/// Artists may lack a backdrop or a photo, so callers pass a fallback list.
actor ZuneImageLoader {
    static let shared = ZuneImageLoader()

    /// URLs that answered with an error, so scrolling back doesn't ask again.
    private var missing = Set<URL>()

    func firstImage(from urls: [URL]) async -> PlatformImage? {
        for url in urls where !missing.contains(url) {
            let key = ImageCacheService.shared.key(for: url)
            if let cached = ImageCacheService.shared.getImage(forKey: key) {
                return cached
            }
            do {
                let (data, response) = try await JellyfinAPIService.urlSession.data(from: url)
                if Task.isCancelled { return nil }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let image = PlatformImage(data: data) else {
                    missing.insert(url)
                    continue
                }
                ImageCacheService.shared.setImage(image, forKey: key)
                return image
            } catch {
                // Network hiccup or cancellation: try again next time.
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }
}

// MARK: - Backdrop

/// Full-bleed artist photo with a slow Ken Burns pan. Wide backdrops on a tall
/// screen pan across their whole width, the way the Zune HD drifted over artist art.
/// Keeps showing the previous photo until the next one has loaded, then crossfades.
struct ZuneBackdrop: View {
    @Environment(\.zuneBackdropPaused) private var paused
    let urls: [URL]
    /// Darkening over the photo so white type stays readable.
    var dim: Double = 0.45

    @State private var image: PlatformImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black

                if let image {
                    KenBurnsImage(image: image, size: geo.size, paused: paused)
                        .id(ObjectIdentifier(image))
                        .transition(.opacity)
                }

                LinearGradient(
                    colors: [.black.opacity(dim * 0.6), .black.opacity(dim), .black.opacity(min(dim + 0.35, 0.95))],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: urls) {
            guard !urls.isEmpty else { return }
            if let loaded = await ZuneImageLoader.shared.firstImage(from: urls), !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.9)) {
                    image = loaded
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct KenBurnsImage: View {
    let image: PlatformImage
    let size: CGSize
    var paused = false

    var body: some View {
        let fill = filledSize
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let scale = 1.08 + 0.05 * sin(t / 17)
            // How far the scaled photo reaches past each edge: the pan never shows black.
            let reachX = max((fill.width * scale - size.width) / 2, 0)
            let reachY = max((fill.height * scale - size.height) / 2, 0)

            Image(platformImage: image)
                .resizable()
                .frame(width: fill.width, height: fill.height)
                .scaleEffect(scale)
                .offset(x: reachX * sin(t / 23), y: reachY * cos(t / 29))
                .frame(width: size.width, height: size.height)
        }
    }

    /// The photo scaled to cover the frame, keeping its aspect ratio.
    private var filledSize: CGSize {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, size.width > 0, size.height > 0 else { return size }
        let scale = max(size.width / imageSize.width, size.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}

// MARK: - Screen scaffold

/// A Zune page: the backdrop photo behind a vertical scroll that opens with a huge
/// lowercase title running off the edge. Pass `scrolledID` and mark the content
/// with `.scrollTargetLayout()` to know which row is at the top.
struct ZuneScreen<Content: View>: View {
    @Environment(\.zunePivotHeaderHeight) private var pivotHeader
    let title: String
    let backdropURLs: [URL]
    var dim: Double = 0.55
    /// Only for pages that follow the top row; a constant binding here would keep
    /// pulling the scroll view back while the finger drags it.
    var scrolledID: Binding<String?>?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ZunePageTitle(text: title)
                content()
            }
            .padding(.bottom, 140)
        }
        .modifier(ZuneTopRowPosition(id: scrolledID))
        #if os(iOS)
        .hidesMiniPlayerOnScroll()
        #endif
        .zuneBackdrop(urls: backdropURLs, dim: dim)
        .zuneChrome()
    }
}

private struct ZuneTopRowPosition: ViewModifier {
    let id: Binding<String?>?

    func body(content: Content) -> some View {
        if let id {
            content.scrollPosition(id: id, anchor: .top)
        } else {
            content
        }
    }
}

/// Follows the row at the top of a long list without re-rendering the list for
/// every row that passes: the id is kept here, outside SwiftUI state, and only
/// reported once scrolling has settled.
@MainActor
final class ZuneTopRowTracker {
    private(set) var id: String?
    private var settle: Task<Void, Never>?

    func binding(onSettle: @escaping (String?) -> Void) -> Binding<String?> {
        Binding(
            get: { self.id },
            set: { newValue in
                self.id = newValue
                self.settle?.cancel()
                self.settle = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    onSettle(newValue)
                }
            }
        )
    }
}

/// The page's giant title; inside the pivot the header already shows it.
struct ZunePageTitle: View {
    @Environment(\.zunePivotHeaderHeight) private var pivotHeader
    let text: String

    var body: some View {
        if pivotHeader == 0 {
            ZuneOverflowText(text: text, size: 80)
                .padding(.leading, 16)
                .padding(.bottom, 8)
        } else {
            Color.clear.frame(height: 4)
        }
    }
}

private struct ZuneBackdropModifier: ViewModifier {
    @Environment(\.zunePivotHeaderHeight) private var pivotHeader
    @Environment(\.zuneBackdropReach) private var reach
    let urls: [URL]
    let dim: Double

    func body(content: Content) -> some View {
        content.background {
            ZuneBackdrop(urls: urls, dim: dim)
                // In the pivot the photo reaches up behind the header.
                .padding(.top, -max(reach, pivotHeader))
                .ignoresSafeArea()
        }
    }
}

extension View {
    func zuneBackdrop(urls: [URL], dim: Double = 0.55) -> some View {
        modifier(ZuneBackdropModifier(urls: urls, dim: dim))
    }

    /// Dark, untitled, transparent navigation bar so the photo runs to the top edge.
    func zuneChrome() -> some View {
        self
            .environment(\.colorScheme, .dark)
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
    }
}

// MARK: - Pieces

struct ZuneSectionTitle: View {
    let text: String

    var body: some View {
        Text(text.lowercased())
            .font(.zune(40, .light, relativeTo: .title))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.top, 32)
            .padding(.bottom, 10)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Zune's text buttons: an outlined circle with the glyph, then a lowercase label.
struct ZuneCircleButton: View {
    var title: String?
    let systemImage: String
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                if let title {
                    Text(title)
                        .font(.zune(20, .regular, relativeTo: .headline))
                }
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Song row: lowercase title, a quieter line under it, the accent color when playing.
/// Tap plays it within `queue`; long press offers favorite and download.
struct ZuneTrackRow: View {
    enum Leading { case none, number(Int), artwork }
    enum Detail { case artist, album, artistAndAlbum }

    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject private var downloadManager = DownloadManager.shared

    let track: AudioItem
    let queue: [AudioItem]
    var leading: Leading = .none
    var detail: Detail = .artistAndAlbum
    var onInfo: ((AudioItem) -> Void)?

    private var isCurrent: Bool { viewModel.currentlyPlayingItem?.id == track.id }

    var body: some View {
        Button {
            if isCurrent {
                viewModel.isPlaying ? viewModel.playerManager.pause() : viewModel.playerManager.play()
            } else {
                viewModel.playerManager.play(item: track, in: queue)
            }
        } label: {
            HStack(spacing: 12) {
                leadingView

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.Name.lowercased())
                        .font(.zune(21, .semilight, relativeTo: .body))
                        .foregroundStyle(isCurrent ? Color.accentColor : .white)
                        .lineLimit(1)
                    if let detailText, !detailText.isEmpty {
                        Text(detailText.lowercased())
                            .font(.zune(14, .regular, relativeTo: .caption))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if isCurrent {
                    Image(systemName: viewModel.isPlaying ? "waveform" : "pause")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, isActive: viewModel.isPlaying)
                }
                if viewModel.isTrackFavorite(track.id) {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
                downloadMark
                if let duration = track.duration {
                    Text(ZuneFormat.time(duration))
                        .font(.zune(15, .regular, relativeTo: .caption).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { menu }
    }

    private var detailText: String? {
        switch detail {
        case .artist: return viewModel.artistName(for: track)
        case .album: return track.Album
        case .artistAndAlbum:
            return [viewModel.artistName(for: track), track.Album].compactMap { $0 }.joined(separator: " · ")
        }
    }

    @ViewBuilder
    private var leadingView: some View {
        switch leading {
        case .none:
            EmptyView()
        case .number(let number):
            Text("\(number)")
                .font(.zune(19, .light, relativeTo: .body).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
                .frame(minWidth: 24, alignment: .trailing)
        case .artwork:
            CachedAsyncImage(url: viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 120), targetSize: 48,
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: { Rectangle().fill(.white.opacity(0.12)) }
            )
            .frame(width: 48, height: 48)
            .clipped()
        }
    }

    @ViewBuilder
    private var downloadMark: some View {
        switch downloadManager.downloadStates[track.Id] ?? .notDownloaded {
        case .notDownloaded:
            EmptyView()
        case .downloading(let progress):
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 14, height: 14)
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private var menu: some View {
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

/// Square cover with no rounding, lowercase name and artist underneath.
struct ZuneAlbumTile: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem
    var size: CGFloat = 150
    var showsArtist = true

    var body: some View {
        NavigationLink(destination: AlbumTracksListView(album: album)) {
            ZuneTile(artworkURL: viewModel.artworkURL(for: album.id, size: 300),
                     title: album.Name,
                     subtitle: showsArtist ? album.AlbumArtist : album.ProductionYear.map(String.init),
                     size: size)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                viewModel.toggleFavoriteAlbum(album.id)
            } label: {
                Label(viewModel.isAlbumFavorite(album.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                      systemImage: viewModel.isAlbumFavorite(album.id) ? "heart.slash" : "heart")
            }
        }
    }
}

/// Square cover for a song: tap plays it.
struct ZuneTrackTile: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let track: AudioItem
    let queue: [AudioItem]
    var size: CGFloat = 150

    var body: some View {
        Button {
            viewModel.playerManager.play(item: track, in: queue)
        } label: {
            ZuneTile(artworkURL: viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 300),
                     title: track.Name,
                     subtitle: viewModel.artistName(for: track),
                     size: size,
                     highlighted: viewModel.currentlyPlayingItem?.id == track.id)
        }
        .buttonStyle(.plain)
    }
}

struct ZuneTile: View {
    let artworkURL: URL?
    let title: String
    let subtitle: String?
    var size: CGFloat = 150
    var highlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            CachedAsyncImage(url: artworkURL, targetSize: size,
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: {
                    Rectangle().fill(.white.opacity(0.12))
                        .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.4)))
                }
            )
            .frame(width: size, height: size)
            .clipped()

            Text(title.lowercased())
                .font(.zune(16, .semilight, relativeTo: .subheadline))
                .foregroundStyle(highlighted ? Color.accentColor : .white)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle.lowercased())
                    .font(.zune(14, .regular, relativeTo: .caption))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        }
        .frame(width: size, alignment: .leading)
    }
}

/// Horizontal strip of tiles that bleeds past both edges.
struct ZuneStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 14) {
                content()
            }
            .padding(.horizontal, 20)
        }
        .scrollClipDisabled()
    }
}

/// Quiet lowercase line for empty states.
struct ZuneNote: View {
    let text: String

    var body: some View {
        Text(text.lowercased())
            .font(.zune(17, .semilight, relativeTo: .subheadline))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.vertical, 6)
    }
}

enum ZuneFormat {
    static func time(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
