// AlbumColorBackground.swift
// Optional app background (Settings > Aspetto): a soft mesh gradient made of the colors of the
// cover that's playing, laid over the system background. It is one layer behind each
// screen's scroll view (never per row). The mesh is painted once per album into a tiny
// bitmap (MeshBitmap) that the GPU stretches; it drifts slowly with a Core Animation
// (no app code per frame) and stands still while scrolling, with Reduce Motion, in the
// background and under the full player. The page color is mixed in by the bitmap's opacity,
// so text stays readable.

import SwiftUI

/// The nine cover colors of one album, as RGB numbers (cheap to cache and to store), and the
/// mesh they make, painted once.
struct AlbumBackdropPalette: Equatable {
    let albumId: String
    /// 3×3 mesh order, row by row from the top; r, g, b in 0...1.
    let rgb: [[Double]]
    /// The mesh as a small bitmap (see MeshBitmap); nil if it couldn't be made.
    let image: CGImage?

    nonisolated init(albumId: String, rgb: [[Double]]) {
        self.albumId = albumId
        self.rgb = rgb
        image = MeshBitmap.make(rgb)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.albumId == rhs.albumId && lhs.rgb == rhs.rgb
    }
}

/// The mesh of nine colors painted into a 48×96 bitmap: smooth (Catmull-Rom) between the
/// colors, a little more saturated than the cover since the page color washes it out. The
/// GPU stretches it to the screen, blurring it further. Costs a fraction of a millisecond,
/// once per album; showing it costs nothing, unlike a MeshGradient redrawn every frame.
enum MeshBitmap {
    nonisolated static let width = 48
    nonisolated static let height = 96

    nonisolated static func make(_ rgb: [[Double]]) -> CGImage? {
        guard rgb.count == 9, rgb.allSatisfy({ $0.count == 3 }) else { return nil }
        let nodes: [[Double]] = rgb.map { c in
            let gray = (c[0] + c[1] + c[2]) / 3
            return c.map { min(max(gray + ($0 - gray) * 1.2, 0), 1) }
        }
        let columns = axisWeights(count: width), rows = axisWeights(count: height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var color = [0.0, 0.0, 0.0]
                for j in 0..<4 {
                    for i in 0..<4 {
                        let weight = rows[y].weights[j] * columns[x].weights[i]
                        let node = nodes[rows[y].nodes[j] * 3 + columns[x].nodes[i]]
                        color[0] += weight * node[0]; color[1] += weight * node[1]; color[2] += weight * node[2]
                    }
                }
                let at = (y * width + x) * 4
                for c in 0..<3 { pixels[at + c] = UInt8(min(max(color[c], 0), 1) * 255 + 0.5) }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// For each pixel along one axis: the four mesh nodes around it (0...2, the ends
    /// repeated) and their Catmull-Rom weights.
    private nonisolated static func axisWeights(count: Int) -> [(nodes: [Int], weights: [Double])] {
        (0..<count).map { pixel in
            let position = (Double(pixel) + 0.5) / Double(count) * 2
            let cell = min(Int(position), 1)
            let t = position - Double(cell), t2 = t * t, t3 = t2 * t
            let nodes = [cell - 1, cell, cell + 1, cell + 2].map { min(max($0, 0), 2) }
            let weights = [0.5 * (-t3 + 2 * t2 - t), 0.5 * (3 * t3 - 5 * t2 + 2),
                           0.5 * (-3 * t3 + 4 * t2 + t), 0.5 * (t3 - t2)]
            return (nodes, weights)
        }
    }
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
        // The nine colors and the bitmap are made away from the main thread.
        let made = await Task.detached(priority: .utility) {
            image.meshSample().map { AlbumBackdropPalette(albumId: albumId, rgb: $0) }
        }.value
        guard let fresh = made, !Task.isCancelled else { return }
        if cache.count > 40 { cache.removeAll() }
        cache[albumId] = fresh
        palette = fresh
        UserDefaults.standard.set(["id": albumId, "rgb": fresh.rgb.flatMap { $0 }], forKey: Self.lastKey)
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

#if os(iOS)
/// Whether the picture may drift right now. Not observable on purpose: a scroll starting or
/// stopping must not redraw any SwiftUI view, it only pauses the Core Animation.
@MainActor
final class BackdropMotion {
    private let views = NSHashTable<DriftView>.weakObjects()

    var scrolling = false {
        didSet {
            guard scrolling != oldValue else { return }
            for view in views.allObjects { view.refresh() }
        }
    }

    fileprivate func register(_ view: DriftView) { views.add(view) }
}

/// The backdrop, with the system background under it. One per screen, behind its scroll view.
struct AlbumColorBackground: View {
    let motion: BackdropMotion
    @ObservedObject private var backdrop = AlbumBackdrop.shared
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // Also still while the full player covers the screen (and while it slides away).
        let drifts = !reduceMotion && scenePhase == .active && !PlayerPresentation.shared.isCovering
        ZStack {
            Color(uiColor: .systemBackground)
            if let palette = backdrop.palette, let image = palette.image {
                DriftingPicture(image: image, opacity: colorScheme == .dark ? 0.5 : 0.36,
                                drifts: drifts, motion: motion)
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
}

private struct DriftingPicture: UIViewRepresentable {
    let image: CGImage
    /// How much of the picture shows over the page color: a pastel wash in light mode, a
    /// dim glow in dark mode.
    let opacity: Float
    let drifts: Bool
    let motion: BackdropMotion

    init(image: CGImage, opacity: Double, drifts: Bool, motion: BackdropMotion) {
        self.image = image
        self.opacity = Float(opacity)
        self.drifts = drifts
        self.motion = motion
    }

    func makeUIView(context: Context) -> DriftView {
        let view = DriftView(image: image, opacity: opacity)
        view.allowsDrift = drifts
        view.motion = motion
        motion.register(view)
        return view
    }

    func updateUIView(_ view: DriftView, context: Context) {
        view.setOpacity(opacity)
        view.allowsDrift = drifts
    }
}

/// The picture on a layer larger than the screen, moved by two Core Animations that run in the
/// render server (an orbit and a slight turn, 36 s and 47 s a cycle, at a low frame rate): the
/// app does nothing per frame. Pausing freezes the layer where it is.
final class DriftView: UIView {
    private let picture = CALayer()
    weak var motion: BackdropMotion?
    var allowsDrift = false { didSet { refresh() } }
    private var running = false
    private var laidOutSize: CGSize = .zero

    init(image: CGImage, opacity: Float) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        picture.contents = image
        picture.opacity = opacity
        picture.magnificationFilter = .linear
        // Starts frozen: `refresh` lets it go when it may.
        picture.speed = 0
        layer.addSublayer(picture)
    }

    required init?(coder: NSCoder) { nil }

    func setOpacity(_ value: Float) {
        if picture.opacity != value { picture.opacity = value }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != laidOutSize, bounds.width > 0 else { return }
        laidOutSize = bounds.size
        // Bigger than the screen, so the drift never shows an edge.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.bounds = CGRect(origin: .zero, size: CGSize(width: bounds.width * 1.4, height: bounds.height * 1.4))
        picture.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        addAnimations()
        refresh()
    }

    private func addAnimations() {
        let range = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 12)
        let orbit = CAKeyframeAnimation(keyPath: "position")
        let rx = bounds.width * 0.06, ry = bounds.height * 0.035
        orbit.path = CGPath(ellipseIn: CGRect(x: bounds.midX - rx, y: bounds.midY - ry, width: rx * 2, height: ry * 2),
                            transform: nil)
        orbit.calculationMode = .paced
        orbit.duration = 36
        orbit.repeatCount = .infinity
        orbit.preferredFrameRateRange = range
        picture.add(orbit, forKey: "orbit")

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = -0.05
        turn.toValue = 0.05
        turn.duration = 47
        turn.autoreverses = true
        turn.repeatCount = .infinity
        turn.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        turn.preferredFrameRateRange = range
        picture.add(turn, forKey: "turn")
    }

    /// Moving only when allowed and while nothing scrolls.
    func refresh() {
        let shouldRun = allowsDrift && !(motion?.scrolling ?? false) && picture.animation(forKey: "orbit") != nil
        guard shouldRun != running else { return }
        running = shouldRun
        if shouldRun {
            // Let go from the frozen time, so it continues instead of jumping.
            let frozenAt = picture.timeOffset
            picture.speed = 1
            picture.timeOffset = 0
            picture.beginTime = 0
            picture.beginTime = picture.convertTime(CACurrentMediaTime(), from: nil) - frozenAt
        } else {
            let now = picture.convertTime(CACurrentMediaTime(), from: nil)
            picture.speed = 0
            picture.timeOffset = now
        }
    }
}
#endif

// MARK: - Applying it

private struct AlbumColorBackgroundModifier: ViewModifier {
    @AppStorage(AlbumBackdrop.storageKey) private var enabled = false
    #if os(iOS)
    @State private var motion = BackdropMotion()
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if enabled {
            // Lists draw their own page color: hide it so the layer behind shows.
            content
                .scrollContentBackground(.hidden)
                .background { AlbumColorBackground(motion: motion) }
                // The picture stands still while the list scrolls (it costs the scroll frames).
                .onScrollPhaseChange { _, phase in motion.scrolling = phase != .idle }
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
