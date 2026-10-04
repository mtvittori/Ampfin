// AmpfinWidget.swift
// amplifin's widgets, on iPhone and Mac:
// - "In riproduzione": the song playing on its cover's color, with real buttons
//   (previous, play/pause, next) and, in the large size, what comes next. Also on
//   the Lock Screen (circular, rectangular, inline).
// - "Ascoltati di recente" and "Preferiti": covers that open their album.
// - Control Center: play/pause and next.
// The app writes WidgetSnapshot into the App Group and reloads the timelines when
// something changes; the widgets only read it.

import WidgetKit
import SwiftUI
import AppIntents
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        let snapshot = context.isPreview ? (WidgetStore.load() ?? .placeholder) : (WidgetStore.load() ?? WidgetSnapshot())
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: WidgetStore.load() ?? WidgetSnapshot())
        // The app reloads on every change; this is only a safety net.
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
    }
}

// MARK: - Pieces

/// A saved cover, or a quiet placeholder. Desaturated in tinted and clear modes.
private struct Cover: View {
    let itemId: String
    var corner: CGFloat = 10

    var body: some View {
        Group {
            if let image = WidgetStore.image(for: itemId) {
                image
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.white.opacity(0.15))
                    .overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6)))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

/// A round button that runs a playback intent in the app.
private struct ControlButton<I: AppIntent>: View {
    let intent: I
    let systemImage: String
    var size: CGFloat = 36
    var filled = false
    let palette: WidgetSnapshot.Palette

    var body: some View {
        Button(intent: intent) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(filled ? palette.background : palette.foreground)
                .frame(width: size, height: size)
                .background(filled ? palette.foreground : palette.foreground.opacity(0.14), in: Circle())
                .widgetAccentable(filled)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Now playing

struct NowPlayingView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WidgetSnapshot

    private var palette: WidgetSnapshot.Palette { snapshot.palette }

    var body: some View {
        Group {
            if let track = snapshot.nowPlaying {
                switch family {
                case .accessoryCircular: circular
                case .accessoryRectangular: rectangular(track)
                case .accessoryInline: inline(track)
                case .systemSmall: small(track)
                case .systemLarge, .systemExtraLarge: large(track)
                default: medium(track)
                }
            } else {
                empty
            }
        }
        .widgetURL(URL(string: "ampfin://player"))
        .containerBackground(for: .widget) {
            palette.background
        }
    }

    private var playPause: some View {
        ControlButton(intent: PlayPauseIntent(), systemImage: snapshot.isPlaying ? "pause.fill" : "play.fill",
                      size: 44, filled: true, palette: palette)
    }

    private func titles(_ track: WidgetSnapshot.Track, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(track.title)
                .font(big ? .title3.weight(.bold) : .headline)
                .foregroundStyle(palette.foreground)
                .lineLimit(big ? 2 : 1)
            Text(track.artist)
                .font(big ? .body : .subheadline)
                .foregroundStyle(palette.secondary)
                .lineLimit(1)
        }
    }

    private func small(_ track: WidgetSnapshot.Track) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Cover(itemId: track.albumId, corner: 10)
                    .frame(width: 68, height: 68)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                Spacer(minLength: 4)
                playPause
            }
            Spacer(minLength: 6)
            titles(track)
        }
    }

    private func medium(_ track: WidgetSnapshot.Track) -> some View {
        HStack(spacing: 14) {
            Cover(itemId: track.albumId, corner: 12)
                .aspectRatio(1, contentMode: .fit)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            VStack(alignment: .leading, spacing: 0) {
                titles(track)
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                        .lineLimit(1)
                        .padding(.top, 2)
                }
                Spacer(minLength: 6)
                HStack(spacing: 10) {
                    ControlButton(intent: PreviousTrackIntent(), systemImage: "backward.fill", palette: palette)
                    playPause
                    ControlButton(intent: NextTrackIntent(), systemImage: "forward.fill", palette: palette)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func large(_ track: WidgetSnapshot.Track) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 14) {
                Cover(itemId: track.albumId, corner: 14)
                    .frame(width: 130, height: 130)
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 10) {
                    titles(track, big: true)
                    HStack(spacing: 10) {
                        ControlButton(intent: PreviousTrackIntent(), systemImage: "backward.fill", palette: palette)
                        playPause
                        ControlButton(intent: NextTrackIntent(), systemImage: "forward.fill", palette: palette)
                    }
                }
            }
            if !snapshot.upNext.isEmpty {
                Text("A seguire")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.secondary)
                ForEach(snapshot.upNext.prefix(3)) { next in
                    HStack(spacing: 10) {
                        Cover(itemId: next.albumId, corner: 6)
                            .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(next.title)
                                .font(.subheadline)
                                .foregroundStyle(palette.foreground)
                                .lineLimit(1)
                            Text(next.artist)
                                .font(.caption)
                                .foregroundStyle(palette.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Button(intent: PlayPauseIntent()) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2.weight(.semibold))
            }
            .buttonStyle(.plain)
        }
    }

    private func rectangular(_ track: WidgetSnapshot.Track) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Label(snapshot.isPlaying ? "In riproduzione" : "In pausa",
                      systemImage: snapshot.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption2.weight(.semibold))
                    .widgetAccentable()
                Text(track.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func inline(_ track: WidgetSnapshot.Track) -> some View {
        Label("\(track.title) · \(track.artist)", systemImage: snapshot.isPlaying ? "waveform" : "music.note")
    }

    @ViewBuilder
    private var empty: some View {
        switch family {
        case .accessoryInline:
            Label("amplifin", systemImage: "music.note")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "music.note").font(.title2)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text("amplifin").font(.headline).widgetAccentable()
                Text("Niente in riproduzione").font(.caption)
            }
        default:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(palette.foreground)
                Spacer()
                Text("Niente in riproduzione")
                    .font(.headline)
                    .foregroundStyle(palette.foreground)
                Text("Tocca per aprire amplifin")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Album grids

struct AlbumGridView: View {
    @Environment(\.widgetFamily) private var family
    let title: String
    let systemImage: String
    let albums: [WidgetSnapshot.Album]
    let emptyText: String

    var body: some View {
        Group {
            if albums.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    header
                    Spacer()
                    Text(emptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if family == .systemSmall, let first = albums.first {
                Link(destination: albumURL(first)) {
                    VStack(alignment: .leading, spacing: 6) {
                        header
                        Cover(itemId: first.id, corner: 10)
                            .aspectRatio(1, contentMode: .fit)
                        Text(first.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    grid
                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(for: .widget) {
            Self.background
        }
    }

    private var header: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .widgetAccentable()
    }

    private var columns: Int { family == .systemExtraLarge ? 6 : (family == .systemLarge ? 3 : 4) }
    private var rows: Int { family == .systemLarge || family == .systemExtraLarge ? 2 : 1 }

    private var grid: some View {
        let shown = Array(albums.prefix(columns * rows))
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(0..<rows, id: \.self) { row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < shown.count {
                            tile(shown[index])
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
    }

    private func tile(_ album: WidgetSnapshot.Album) -> some View {
        Link(destination: albumURL(album)) {
            VStack(alignment: .leading, spacing: 3) {
                Cover(itemId: album.id, corner: 8)
                    .aspectRatio(1, contentMode: .fit)
                if family != .systemMedium {
                    Text(album.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(album.artist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The system background on both platforms.
    private static var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    private func albumURL(_ album: WidgetSnapshot.Album) -> URL {
        URL(string: "ampfin://album/\(album.id)")!
    }
}


// MARK: - Widgets

struct AmpfinNowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.nowPlaying, provider: SnapshotProvider()) { entry in
            NowPlayingView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("In riproduzione")
        .description("Il brano in ascolto sul colore della sua copertina, con i comandi e cosa viene dopo.")
        .supportedFamilies(Self.families)
    }

    static var families: [WidgetFamily] {
        #if os(iOS)
        return [.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        return [.systemSmall, .systemMedium, .systemLarge]
        #endif
    }
}

struct AmpfinRecentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.recent, provider: SnapshotProvider()) { entry in
            AlbumGridView(title: "Ascoltati di recente", systemImage: "clock.arrow.circlepath",
                          albums: entry.snapshot.recentAlbums, emptyText: "Ascolta qualcosa e lo ritrovi qui.")
        }
        .configurationDisplayName("Ascoltati di recente")
        .description("Gli ultimi album ascoltati: toccane uno per aprirlo.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct AmpfinFavoritesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.favorites, provider: SnapshotProvider()) { entry in
            AlbumGridView(title: "Preferiti", systemImage: "heart.fill",
                          albums: entry.snapshot.favoriteAlbums, emptyText: "Tocca il cuore su un album per vederlo qui.")
        }
        .configurationDisplayName("Album preferiti")
        .description("I tuoi album preferiti: toccane uno per aprirlo.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Control Center

#if os(iOS)
struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "AmpfinPlayPause") {
            ControlWidgetButton(action: PlayPauseIntent()) {
                Label("amplifin", systemImage: "playpause.fill")
            }
        }
        .displayName("Riproduci/Pausa")
        .description("Mette in pausa o riprende la musica di amplifin.")
    }
}

struct NextTrackControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "AmpfinNext") {
            ControlWidgetButton(action: NextTrackIntent()) {
                Label("Successivo", systemImage: "forward.fill")
            }
        }
        .displayName("Brano successivo")
        .description("Passa al brano successivo in amplifin.")
    }
}
#endif
