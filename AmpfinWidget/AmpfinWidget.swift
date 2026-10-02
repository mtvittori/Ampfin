import WidgetKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// NowPlayingInfo and SharedDefaults are defined in Ampfin/Shared/NowPlayingInfo.swift
// which is included in both the main app and widget targets.

// MARK: - Color Extraction

/// Extracts dominant colors from a CGImage by sampling pixels in a grid.
private func extractColors(from cgImage: CGImage) -> (primary: Color, secondary: Color) {
    let width = 40
    let height = 40
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        return (.gray, .gray.opacity(0.5))
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else {
        return (.gray, .gray.opacity(0.5))
    }
    let pointer = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

    // Collect color buckets (simplified k-means with 2 clusters)
    var rSum1: Double = 0, gSum1: Double = 0, bSum1: Double = 0, count1: Double = 0
    var rSum2: Double = 0, gSum2: Double = 0, bSum2: Double = 0, count2: Double = 0

    let totalPixels = width * height
    for i in 0..<totalPixels {
        let offset = i * 4
        let r = Double(pointer[offset])
        let g = Double(pointer[offset + 1])
        let b = Double(pointer[offset + 2])

        // Brightness threshold to separate light/dark regions
        let brightness = (r + g + b) / (3.0 * 255.0)
        if brightness > 0.5 {
            rSum1 += r; gSum1 += g; bSum1 += b; count1 += 1
        } else {
            rSum2 += r; gSum2 += g; bSum2 += b; count2 += 1
        }
    }

    let primary: Color
    let secondary: Color

    if count1 > 0 && count2 > 0 {
        // Use the darker cluster as primary, lighter as secondary
        primary = Color(
            red: rSum2 / (count2 * 255),
            green: gSum2 / (count2 * 255),
            blue: bSum2 / (count2 * 255)
        )
        secondary = Color(
            red: rSum1 / (count1 * 255),
            green: gSum1 / (count1 * 255),
            blue: bSum1 / (count1 * 255)
        )
    } else {
        let total = count1 + count2
        let rAll = (rSum1 + rSum2) / max(total, 1)
        let gAll = (gSum1 + gSum2) / max(total, 1)
        let bAll = (bSum1 + bSum2) / max(total, 1)
        primary = Color(red: rAll / 255, green: gAll / 255, blue: bAll / 255)
        secondary = primary.opacity(0.6)
    }

    return (primary, secondary)
}

// MARK: - Timeline Provider

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(
            date: Date(),
            trackName: "Titolo brano",
            artistName: "Artista",
            albumName: "Album",
            isPlaying: true,
            artworkImage: nil,
            primaryColor: .gray,
            secondaryColor: .gray.opacity(0.5)
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        buildEntry { entry in
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        buildEntry { entry in
            let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date()
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }
    }

    private func buildEntry(completion: @escaping (NowPlayingEntry) -> Void) {
        guard let info = SharedDefaults.loadNowPlaying() else {
            completion(NowPlayingEntry(
                date: Date(),
                trackName: nil,
                artistName: nil,
                albumName: nil,
                isPlaying: false,
                artworkImage: nil,
                primaryColor: .gray,
                secondaryColor: .gray.opacity(0.5)
            ))
            return
        }

        let artworkURLString = info.artworkURLString
        guard !artworkURLString.isEmpty, let url = URL(string: artworkURLString) else {
            completion(NowPlayingEntry(
                date: Date(),
                trackName: info.trackName,
                artistName: info.artistName,
                albumName: info.albumName,
                isPlaying: info.isPlaying,
                artworkImage: nil,
                primaryColor: .gray,
                secondaryColor: .gray.opacity(0.5)
            ))
            return
        }

        // Download artwork synchronously on the timeline provider's background thread
        var request = URLRequest(url: url)
        // Add auth token header for Jellyfin
        if !info.token.isEmpty {
            request.setValue("MediaBrowser Token=\"\(info.token)\"", forHTTPHeaderField: "Authorization")
        }

        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            var image: Image? = nil
            var primary: Color = .gray
            var secondary: Color = .gray.opacity(0.5)

            #if os(macOS)
            if let data, let nsImage = NSImage(data: data),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                image = Image(nsImage: nsImage)
                let colors = extractColors(from: cgImage)
                primary = colors.primary
                secondary = colors.secondary
            }
            #else
            if let data, let uiImage = UIImage(data: data),
               let cgImage = uiImage.cgImage {
                image = Image(uiImage: uiImage)
                let colors = extractColors(from: cgImage)
                primary = colors.primary
                secondary = colors.secondary
            }
            #endif

            completion(NowPlayingEntry(
                date: Date(),
                trackName: info.trackName,
                artistName: info.artistName,
                albumName: info.albumName,
                isPlaying: info.isPlaying,
                artworkImage: image,
                primaryColor: primary,
                secondaryColor: secondary
            ))
        }
        task.resume()
    }
}

// MARK: - Timeline Entry

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let isPlaying: Bool
    let artworkImage: Image?
    let primaryColor: Color
    let secondaryColor: Color
}

// MARK: - Widget Views

struct NowPlayingWidgetView: View {
    @Environment(\.widgetFamily) var family
    var entry: NowPlayingEntry

    var body: some View {
        if let trackName = entry.trackName {
            switch family {
            case .systemSmall:
                smallView(trackName: trackName)
            case .systemMedium:
                mediumView(trackName: trackName)
            default:
                mediumView(trackName: trackName)
            }
        } else {
            emptyStateView
        }
    }

    // MARK: - Small Widget

    private func smallView(trackName: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: entry.isPlaying ? "waveform" : "pause.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
            }

            Spacer()

            // Artwork
            if let image = entry.artworkImage {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(trackName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let artist = entry.artistName {
                    Text(artist)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [entry.secondaryColor, entry.primaryColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Medium Widget

    private func mediumView(trackName: String) -> some View {
        HStack(spacing: 14) {
            // Artwork
            if let image = entry.artworkImage {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.white.opacity(0.15))
                    .frame(width: 80, height: 80)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.5))
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: entry.isPlaying ? "waveform" : "pause.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                    Text(entry.isPlaying ? "In riproduzione" : "In pausa")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.6))
                }

                Text(trackName)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let artist = entry.artistName {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }

                if let album = entry.albumName, !album.isEmpty {
                    Text(album)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [entry.secondaryColor, entry.primaryColor],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Nessun brano in riproduzione")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

// MARK: - Widget Configuration

struct AmpfinNowPlayingWidget: Widget {
    let kind: String = "AmpfinNowPlaying"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("In riproduzione")
        .description("Mostra il brano attualmente in riproduzione su amplifin.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
