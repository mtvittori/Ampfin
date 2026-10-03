// Motion.swift
// Movement for the classic Liquid Glass look, borrowed from the Plancia and Passo apps:
// staggered entrances, zoom transitions from a cover to its page, a living mesh
// gradient made from the artwork's colors, and covers that tilt as they scroll.
// With Reduce Motion on, nothing moves.

import SwiftUI

// MARK: - Curves

extension Animation {
    /// Plancia's `--morbido`: quick start, long soft landing.
    static func soft(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }
    /// Plancia's `--molla`: the same with a hint of overshoot.
    static func springy(_ duration: Double) -> Animation { .timingCurve(0.2, 0.9, 0.25, 1.15, duration: duration) }
}

// MARK: - Entrances

enum Entrance {
    /// Rises 18 pt while fading in.
    case rise
    /// Grows from 0.85 with a little overshoot.
    case pop
    /// Slides in from 40 pt to the right.
    case slide

    fileprivate var animation: Animation {
        switch self {
        case .rise: return .soft(0.55)
        case .pop: return .springy(0.6)
        case .slide: return .soft(0.7)
        }
    }
}

private struct Enter: ViewModifier {
    let kind: Entrance
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let on = shown || reduceMotion
        content
            .opacity(on ? 1 : 0)
            .offset(x: kind == .slide && !on ? 40 : 0, y: kind == .rise && !on ? 18 : 0)
            .scaleEffect(kind == .pop && !on ? 0.85 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                // Replays every time the screen comes back, like the card's `entra` class.
                var reset = Transaction()
                reset.disablesAnimations = true
                withTransaction(reset) { shown = false }
                withAnimation(kind.animation.delay(delay)) { shown = true }
            }
    }
}

extension View {
    /// `.entrance(.rise, delay: 0.08)`; pass `enabled: false` to show the view as is
    /// (list rows that scroll into view later shouldn't replay it).
    @ViewBuilder
    func entrance(_ kind: Entrance, delay: Double = 0, enabled: Bool = true) -> some View {
        if enabled {
            modifier(Enter(kind: kind, delay: delay))
        } else {
            self
        }
    }
}

// MARK: - Zoom transitions

extension EnvironmentValues {
    /// Namespace shared by a navigation stack's covers and the pages they open.
    @Entry var zoomNamespace: Namespace.ID?
}

/// Gives the stack inside it a namespace for zoom transitions.
struct ZoomScope<Content: View>: View {
    @Namespace private var namespace
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().environment(\.zoomNamespace, namespace)
    }
}

private struct ZoomSource: ViewModifier {
    @Environment(\.zoomNamespace) private var namespace
    let id: String

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

private struct ZoomDestination: ViewModifier {
    @Environment(\.zoomNamespace) private var namespace
    let id: String

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// The cover a page zooms out of.
    func zoomSource(_ id: String) -> some View { modifier(ZoomSource(id: id)) }
    /// The page that zooms out of the cover with the same id.
    func zoomDestination(_ id: String) -> some View { modifier(ZoomDestination(id: id)) }
}

// MARK: - Cover flow

extension View {
    /// Covers in a horizontal strip shrink, dim and turn slightly as they leave the middle.
    func coverFlow() -> some View {
        scrollTransition(.interactive, axis: .horizontal) { content, phase in
            content
                .scaleEffect(phase.isIdentity ? 1 : 0.88)
                .opacity(phase.isIdentity ? 1 : 0.7)
                .rotation3DEffect(.degrees(phase.value * -14), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        }
    }

    /// Grid items settle in as they scroll onto the screen.
    func gridSettle() -> some View {
        scrollTransition(.animated(.soft(0.5))) { content, phase in
            content
                .opacity(phase.isIdentity ? 1 : 0.35)
                .scaleEffect(phase.isIdentity ? 1 : 0.92)
                .blur(radius: phase.isIdentity ? 0 : 3)
        }
    }
}

// MARK: - Living background

/// A slowly drifting mesh gradient made of the artwork's own colors: nine samples
/// of the cover laid out on a 3×3 mesh whose inner points wander. Behind Liquid Glass
/// it gives the material something to refract.
struct AuroraBackground: View {
    let imageURL: URL?
    /// How strongly it shows over the system background.
    var strength: Double = 0.55

    @State private var colors: [Color]?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if let colors {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
                    MeshGradient(width: 3, height: 3,
                                 points: Self.points(at: context.date.timeIntervalSinceReferenceDate),
                                 colors: colors,
                                 smoothsColors: true)
                }
                .opacity(colorScheme == .dark ? strength : strength * 0.8)
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: imageURL) {
            guard let imageURL,
                  let image = await ZuneImageLoader.shared.firstImage(from: [imageURL]),
                  let sampled = image.meshColors() else { return }
            withAnimation(.easeInOut(duration: 1.2)) {
                colors = sampled
            }
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

extension PlatformImage {
    /// The cover shrunk to 3×3 pixels: nine colors in mesh order, a little more saturated.
    func meshColors() -> [Color]? {
        guard let cgImage = self.cgImage else { return nil }
        let size = 3
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))
        let pixels = data.assumingMemoryBound(to: UInt8.self)

        var colors: [Color] = []
        // The bitmap's first row is the top of the image, like the mesh's.
        for row in 0..<size {
            for column in 0..<size {
                let i = (row * size + column) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                colors.append(Self.vivid(r, g, b))
            }
        }
        return colors
    }

    /// Pushes a color away from its gray by 35%.
    private static func vivid(_ r: Double, _ g: Double, _ b: Double) -> Color {
        let gray = (r + g + b) / 3
        func push(_ c: Double) -> Double { min(max(gray + (c - gray) * 1.35, 0), 1) }
        return Color(red: push(r), green: push(g), blue: push(b))
    }
}

// MARK: - Player artwork

extension View {
    /// The same cover in the mini player and the full player, so it grows from one to the other.
    @ViewBuilder
    func playerArtwork(in namespace: Namespace.ID?) -> some View {
        if let namespace {
            matchedGeometryEffect(id: "playerArtwork", in: namespace)
        } else {
            self
        }
    }
}

// MARK: - Breathing

private struct Breathing: ViewModifier {
    let enabled: Bool
    let moving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if enabled {
            breathing(content)
        } else {
            content
        }
    }

    /// Pausing keeps the current frame, so the cover just stops where it is.
    private func breathing(_ content: Content) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !moving || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            content
                // Oversized enough that the slow turn never uncovers a corner.
                .scaleEffect(1.22 + 0.06 * sin(t / 4))
                .rotationEffect(.degrees(3 * sin(t / 7)))
        }
    }
}

extension View {
    /// Slow swell and turn for a blurred cover behind the player; it moves only while `moving`.
    func breathing(_ enabled: Bool, moving: Bool) -> some View {
        modifier(Breathing(enabled: enabled, moving: moving))
    }
}

// MARK: - Press feedback

/// Covers and cards sink a little under the finger and spring back, like glass does.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Playback clock

/// Reads the playback position for its content only (see PlaybackClock).
struct ClockReader<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    @ViewBuilder let content: (TimeInterval) -> Content

    var body: some View { content(clock.time) }
}
