// AlbumColorBackground.swift
// Optional app background (Settings > Aspetto): a soft mesh gradient made of the colors of the
// cover that's playing, laid over the system background. It is one layer behind each
// screen's scroll view (never per row), computed once per album and mixed toward white
// or black so the text on top stays readable. Same idea as the old "AuroraBackground".

import SwiftUI

/// The nine cover colors of one album, as RGB numbers (cheap to cache and to store).
struct AlbumBackdropPalette: Equatable {
    let albumId: String
    /// 3×3 mesh order, row by row from the top; r, g, b in 0...1.
    let rgb: [[Double]]
}

@MainActor
final class AlbumBackdrop: ObservableObject {
    static let shared = AlbumBackdrop()
    static let storageKey = "albumColorBackground"
    private static let lastKey = "albumBackdropLast"

    /// The playing album's palette; kept after playback stops, and across launches, so
    /// the background falls back to the last played album.
    @Published private(set) var palette: AlbumBackdropPalette?
    private var cache: [String: AlbumBackdropPalette] = [:]

    private init() {
        if let saved = UserDefaults.standard.dictionary(forKey: Self.lastKey),
           let id = saved["id"] as? String, let flat = saved["rgb"] as? [Double], flat.count == 27 {
            palette = AlbumBackdropPalette(albumId: id, rgb: stride(from: 0, to: 27, by: 3).map { Array(flat[$0..<$0 + 3]) })
        }
    }

    /// Called when the playing album changes. Reads the cover through the shared loader (usually
    /// already cached by the accent) and samples it off the main thread.
    func show(albumId: String, url: URL?) async {
        if let cached = cache[albumId] {
            if palette != cached { palette = cached }
            return
        }
        guard let url, let image = await ImageLoader.shared.firstImage(from: [url]) else { return }
        let rgb = await Task.detached(priority: .utility) { image.meshSample() }.value
        guard let rgb, !Task.isCancelled else { return }
        let fresh = AlbumBackdropPalette(albumId: albumId, rgb: rgb)
        if cache.count > 40 { cache.removeAll() }
        cache[albumId] = fresh
        palette = fresh
        UserDefaults.standard.set(["id": albumId, "rgb": rgb.flatMap { $0 }], forKey: Self.lastKey)
    }
}

extension PlatformImage {
    /// The cover shrunk to 3×3 pixels: nine colors in mesh order.
    nonisolated func meshSample() -> [[Double]]? {
        guard let cgImage = self.cgImage else { return nil }
        let size = 3
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        var colors: [[Double]] = []
        // The bitmap's first row is the top of the image, like the mesh's (drawn the other
        // way round the colors came out upside down).
        for row in 0..<size {
            for column in 0..<size {
                let i = (row * size + column) * 4
                colors.append([Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255])
            }
        }
        return colors
    }
}

/// The mesh itself, with the system background under it.
struct AlbumColorBackground: View {
    @ObservedObject private var backdrop = AlbumBackdrop.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            #if os(iOS)
            Color(uiColor: .systemBackground)
            #else
            Color(nsColor: .windowBackgroundColor)
            #endif
            if let palette = backdrop.palette {
                AlbumMesh(colors: Self.adapted(palette.rgb, dark: colorScheme == .dark))
                    .id(palette.albumId)
                    .transition(.opacity)
            }
        }
        // Crossfade when the album changes.
        .animation(.easeInOut(duration: 1.2), value: backdrop.palette?.albumId)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Mixes each color toward the page color (white / black): a pastel wash in light
    /// mode, a dim glow in dark mode, so text keeps its contrast whatever the cover.
    private static func adapted(_ rgb: [[Double]], dark: Bool) -> [Color] {
        let amount = dark ? 0.5 : 0.36
        let base = dark ? 0.0 : 1.0
        return rgb.map { c in
            let gray = (c[0] + c[1] + c[2]) / 3
            func mix(_ v: Double) -> Double {
                // A little more saturation first, since the mix washes it out.
                let pushed = min(max(gray + (v - gray) * 1.2, 0), 1)
                return base * (1 - amount) + pushed * amount
            }
            return Color(red: mix(c[0]), green: mix(c[1]), blue: mix(c[2]))
        }
    }
}

/// A slow drift of the inner points. Redraws ~10 times a second, and not at all with Reduce
/// Motion or while the app is in the background; no state is written per frame.
private struct AlbumMesh: View {
    let colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Also paused while the full player covers the screen (and while it slides away):
        // a full-screen mesh redrawn ten times a second under it only steals frames.
        let paused = reduceMotion || scenePhase != .active || PlayerPresentation.shared.isCovering
        TimelineView(.animation(minimumInterval: 0.1, paused: paused)) { context in
            MeshGradient(width: 3, height: 3,
                         points: Self.points(at: reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate),
                         colors: colors,
                         smoothsColors: true)
        }
    }

    /// Corners stay put, edge points slide along their edge, the center wanders.
    private static func points(at t: TimeInterval) -> [SIMD2<Float>] {
        func w(_ speed: Double, _ phase: Double, _ amount: Double) -> Float {
            Float(amount * sin(t * speed + phase))
        }
        return [
            [0, 0], [0.5 + w(0.31, 0, 0.18), 0], [1, 0],
            [0, 0.5 + w(0.27, 1, 0.18)], [0.5 + w(0.21, 2, 0.22), 0.5 + w(0.25, 3, 0.22)], [1, 0.5 + w(0.33, 4, 0.18)],
            [0, 1], [0.5 + w(0.29, 5, 0.18), 1], [1, 1]
        ]
    }
}

// MARK: - Applying it

private struct AlbumColorBackgroundModifier: ViewModifier {
    @AppStorage(AlbumBackdrop.storageKey) private var enabled = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if enabled {
            // Lists draw their own page color: hide it so the layer behind shows.
            content
                .scrollContentBackground(.hidden)
                .background { AlbumColorBackground() }
                // The rows read this to drop their own opaque background (albumBackdropRow()).
                .environment(\.albumBackdropActive, true)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension EnvironmentValues {
    /// True under albumColorBackground() when the setting is on.
    @Entry var albumBackdropActive = false
}

private struct AlbumBackdropRowModifier: ViewModifier {
    @Environment(\.albumBackdropActive) private var active

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.listRowBackground(Color.clear)
        } else {
            content
        }
    }
}

extension View {
    /// The cover-colored background of the main iOS screens, when the setting is on.
    func albumColorBackground() -> some View { modifier(AlbumColorBackgroundModifier()) }

    /// On a row of a list under albumColorBackground(): clear, so the tint shows through.
    func albumBackdropRow() -> some View { modifier(AlbumBackdropRowModifier()) }
}
