// MacComponents.swift
// Small pieces shared by the Mac screens, which follow the layout of Music on macOS:
// covers with a soft shadow, round artist photos, track rows and the duration format.

#if os(macOS)
import SwiftUI

extension AudioItem {
    // Non-optional sort keys for the songs Table.
    var sortTitle: String { Name }
    var sortArtist: String { mainArtistName ?? "" }
    var sortAlbum: String { Album ?? "" }
    var sortDuration: TimeInterval { duration ?? 0 }
}

enum MacFormat {
    /// "3:45", or "1:02:10" past the hour.
    static func clock(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "12 brani, 48 minuti".
    static func summary(tracks: [AudioItem]) -> String {
        let minutes = Int((tracks.reduce(0) { $0 + ($1.duration ?? 0) } / 60).rounded())
        let count = tracks.count == 1 ? "1 brano" : "\(tracks.count) brani"
        return minutes >= 120 ? "\(count), \(minutes / 60) ore \(minutes % 60) minuti" : "\(count), \(minutes) minuti"
    }
}

/// A square cover with rounded corners and the soft shadow Music puts under them.
struct MacCover: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let itemId: String
    var size: CGFloat? = nil
    var radius: CGFloat = 8
    var imageSize: Int = 400

    var body: some View {
        // A square that takes the width it is offered; the picture is cropped to fit it,
        // so covers that aren't square never push their cell wider.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .overlay {
                CachedAsyncImage(url: viewModel.artworkURL(for: itemId, size: imageSize), targetSize: CGFloat(imageSize)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.tertiary))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: radius > 12 ? 14 : 5, y: radius > 12 ? 6 : 2)
    }
}

/// An artist's round photo, with their initial when the server has none.
struct MacArtistAvatar: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let artist: ArtistItem
    var size: CGFloat? = nil
    @State private var image: PlatformImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(width: size, height: size)
            .overlay {
                ZStack {
                    Circle().fill(.quaternary)
                    if let image {
                        Image(platformImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Text(String(artist.Name.first.map(String.init) ?? "?").uppercased())
                            .font(.system(size: (size ?? 120) * 0.4, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.primary.opacity(0.08)))
            .task(id: artist.Id) {
                let urls = viewModel.artistImageURLs(for: artist, maxWidth: 500).reversed()
                image = await ImageLoader.shared.firstImage(from: Array(urls))
            }
    }
}

// MARK: - Buttons

/// "Riproduci" and "Casuale", the two big buttons under a title.
struct MacPlayButtons: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let tracks: [AudioItem]

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let first = tracks.first { viewModel.playerManager.play(item: first, in: tracks) }
            } label: {
                Label("Riproduci", systemImage: "play.fill").frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)

            Button {
                viewModel.playerManager.playAlbumShuffled(tracks: tracks)
            } label: {
                Label("Casuale", systemImage: "shuffle").frame(minWidth: 90)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(tracks.isEmpty)
    }
}

// MARK: - Track row

/// One song in a list on an album or artist page: number (or speaker, or play on hover),
/// title, optional detail, duration. Double click plays, right click opens the menu.
struct MacTrackRow: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let track: AudioItem
    let number: Int?
    let queue: [AudioItem]
    var detail: String? = nil
    var showsCover = false
    var striped = false
    @Binding var selection: String?
    var onInfo: (AudioItem) -> Void = { _ in }

    @State private var hovering = false

    private var isCurrent: Bool { viewModel.currentlyPlayingItem?.id == track.id }
    private var isSelected: Bool { selection == track.id }

    var body: some View {
        HStack(spacing: 12) {
            leading
                .frame(width: showsCover ? 36 : 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.Name)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : (isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary)))
                    .lineLimit(1)
                if showsCover, let artist = viewModel.artistName(for: track) {
                    Text(artist).font(.caption).foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if let detail {
                Text(detail)
                    .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            if viewModel.isTrackFavorite(track.id) {
                Image(systemName: "heart.fill").font(.caption).foregroundStyle(isSelected ? .white : .pink)
            }
            Text(MacFormat.clock(track.duration ?? 0))
                .monospacedDigit()
                .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: showsCover ? 48 : 36)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.accentColor)
            } else if hovering {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.07))
            } else if striped {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.primary.opacity(0.035))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { play() }
        .onTapGesture { selection = track.id }
        .contextMenu {
            Button { play() } label: { Label("Riproduci", systemImage: "play.fill") }
            QueueMenuItems(tracks: [track]).environmentObject(viewModel)
            Divider()
            Button {
                viewModel.toggleFavoriteTrack(track.id)
            } label: {
                Label(viewModel.isTrackFavorite(track.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                      systemImage: viewModel.isTrackFavorite(track.id) ? "heart.slash" : "heart")
            }
            Button { onInfo(track) } label: { Label("Informazioni", systemImage: "info.circle") }
        }
    }

    @ViewBuilder
    private var leading: some View {
        if showsCover {
            ZStack {
                MacCover(itemId: track.AlbumId ?? track.id, size: 36, radius: 4, imageSize: 100)
                if isCurrent || hovering { playOverlay }
            }
        } else if isCurrent && !hovering {
            Image(systemName: viewModel.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                .font(.caption)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
        } else if hovering {
            Button(action: play) { Image(systemName: "play.fill").font(.caption) }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .white : .primary)
        } else if let number {
            Text("\(number)").monospacedDigit().foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
        }
    }

    private var playOverlay: some View {
        Image(systemName: isCurrent && !hovering ? "speaker.wave.2.fill" : "play.fill")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private func play() {
        viewModel.playerManager.play(item: track, in: queue)
    }
}

// MARK: - Album card

/// A cover in a grid with the title and artist under it. A play button shows on hover.
struct MacAlbumCard: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: album) {
            VStack(alignment: .leading, spacing: 8) {
                MacCover(itemId: album.id, radius: 8, imageSize: 400)
                    .overlay(alignment: .bottomLeading) {
                        if hovering {
                            Button {
                                Task {
                                    let tracks = await viewModel.tracks(ofAlbum: album)
                                    if let first = tracks.first { viewModel.playerManager.play(item: first, in: tracks) }
                                }
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .padding(8)
                            .transition(.opacity)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.Name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(album.AlbumArtist ?? "Artista sconosciuto")
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button {
                Task {
                    let tracks = await viewModel.tracks(ofAlbum: album)
                    if let first = tracks.first { viewModel.playerManager.play(item: first, in: tracks) }
                }
            } label: { Label("Riproduci", systemImage: "play.fill") }
            AlbumQueueMenuItems(album: album).environmentObject(viewModel)
            Divider()
            Button {
                viewModel.toggleFavoriteAlbum(album.id)
            } label: {
                Label(viewModel.isAlbumFavorite(album.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti",
                      systemImage: viewModel.isAlbumFavorite(album.id) ? "heart.slash" : "heart")
            }
        }
    }
}

/// Grid used for albums everywhere: Music's roomy covers, 24 pt between them.
let macAlbumColumns = [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 24, alignment: .top)]

/// The big title at the top of a library section, with a smaller line under it
/// ("908 album"). The window toolbar shows no title, as in Music.
struct MacPageHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 28, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A page title in the content area, like "Aggiunti di recente" above a strip.
struct MacSectionTitle: View {
    let title: String
    var body: some View {
        Text(title).font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
    }
}
#endif
