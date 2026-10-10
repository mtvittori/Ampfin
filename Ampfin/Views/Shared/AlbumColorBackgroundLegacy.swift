// AlbumColorBackgroundLegacy.swift
// The first album-color background, kept as an option (Settings > Aspetto > Resa dello sfondo):
// a MeshGradient redrawn 10 times a second behind each screen. It costs more battery and frames
// than the bitmap renderer in AlbumColorBackground.swift, which stays the default. Kept to
// compare and to rework later; it reads the same AlbumBackdrop palette.

import SwiftUI

#if os(iOS)
/// The mesh itself, with the system background under it.
struct LegacyAlbumColorBackground: View {
    @ObservedObject private var backdrop = AlbumBackdrop.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if let palette = backdrop.palette {
                LegacyAlbumMesh(colors: Self.adapted(palette.rgb, dark: colorScheme == .dark))
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
private struct LegacyAlbumMesh: View {
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
#endif
