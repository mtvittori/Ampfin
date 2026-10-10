// AlbumColorBackground.swift
// Optional app background (Settings > Aspetto): a soft mesh gradient made of the colors of the
// cover that's playing, laid over the system background. It is one layer behind each
// screen's scroll view (never per row). The mesh is painted once per album into a tiny
// bitmap (MeshBitmap) that the GPU stretches; it drifts slowly with a Core Animation
// (no app code per frame) and stands still while scrolling, with Reduce Motion, in the
// background and under the full player. The page color is mixed in by the bitmap's opacity,
// so text stays readable. How much of the original MeshGradient look it adds back is the
// "Resa dello sfondo" slider (AlbumBackdropProfile): 0 is this static bitmap, 1 the old
// full-screen MeshGradient (AlbumColorBackgroundLegacy.swift), in between the bitmap is
// repainted off the main thread with the mesh points really moving, more often the higher it is.

import SwiftUI

/// The nine cover colors of one album, as RGB numbers (cheap to cache and to store), and the
/// mesh they make, painted once.
struct AlbumBackdropPalette: Equatable {
    let albumId: String
    /// 3×3 mesh order, row by row from the top; r, g, b in 0...1.
    let rgb: [[Double]]
    /// The mesh as a small bitmap (see MeshBitmap); nil if it couldn't be made.
    let image: CGImage?
    /// The colors as the bitmap painter wants them (see MeshBitmap.nodes); empty if invalid.
    let nodes: [Float]

    nonisolated init(albumId: String, rgb: [[Double]]) {
        self.albumId = albumId
        self.rgb = rgb
        nodes = MeshBitmap.nodes(rgb)
        image = MeshBitmap.render(nodes: nodes, points: MeshBitmap.restPoints, width: MeshBitmap.width, height: MeshBitmap.height)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.albumId == rhs.albumId && lhs.rgb == rhs.rgb
    }
}

/// The mesh of nine colors painted into a small bitmap (48×96 at rest): smooth (Catmull-Rom)
/// between the colors, a little more saturated than the cover since the page color washes it
/// out. The GPU stretches it to the screen, blurring it further. At rest it costs a fraction of
/// a millisecond, once per album; with moving points (the slider above 0) it is repainted a few
/// times a second, always off the main thread.
enum MeshBitmap {
    nonisolated static let width = 48
    nonisolated static let height = 96

    /// The 3×3 mesh points at rest, row by row, in 0...1 (the same grid MeshGradient gets).
    nonisolated static let restPoints: [SIMD2<Float>] = (0..<9).map { SIMD2(Float($0 % 3) / 2, Float($0 / 3) / 2) }

    /// The nine colors, a little more saturated, flattened to r, g, b per node.
    nonisolated static func nodes(_ rgb: [[Double]]) -> [Float] {
        guard rgb.count == 9, rgb.allSatisfy({ $0.count == 3 }) else { return [] }
        return rgb.flatMap { c -> [Float] in
            let gray = (c[0] + c[1] + c[2]) / 3
            return c.map { Float(min(max(gray + ($0 - gray) * 1.2, 0), 1)) }
        }
    }

    /// Paints the mesh with its points where `points` says. Each pixel is pulled back through a
    /// smooth displacement field (the points' shifts from rest, blended with a smoothstep) and
    /// takes the Catmull-Rom color there: for the small shifts used (< 0.25) the colors follow
    /// the points like MeshGradient does, at a fraction of its cost.
    nonisolated static func render(nodes: [Float], points: [SIMD2<Float>], width: Int, height: Int) -> CGImage? {
        guard nodes.count == 27, points.count == 9 else { return nil }
        let shifts = zip(points, restPoints).map { $0 - $1 }
        // Per column / row: the cell of the 2×2 grid and the smoothstep weight inside it.
        func axis(_ count: Int) -> [(cell: Int, smooth: Float)] {
            (0..<count).map { pixel in
                let position = (Float(pixel) + 0.5) / Float(count) * 2
                let cell = min(Int(position), 1)
                let t = position - Float(cell)
                return (cell, t * t * (3 - 2 * t))
            }
        }
        let columns = axis(width), rows = axis(height)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        nodes.withUnsafeBufferPointer { node in
            pixels.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let row = rows[y]
                    let py = (Float(y) + 0.5) / Float(height)
                    for x in 0..<width {
                        let column = columns[x]
                        let px = (Float(x) + 0.5) / Float(width)
                        // Displacement here: bilinear (smoothstep) between the cell's four points.
                        let i0 = row.cell * 3 + column.cell
                        let top = shifts[i0] + (shifts[i0 + 1] - shifts[i0]) * column.smooth
                        let bottom = shifts[i0 + 3] + (shifts[i0 + 4] - shifts[i0 + 3]) * column.smooth
                        let shift = top + (bottom - top) * row.smooth
                        let s = min(max((px - shift.x) * 2, 0), 2), t = min(max((py - shift.y) * 2, 0), 2)
                        // Catmull-Rom weights along both axes at (s, t).
                        let (cx, wx) = catmullRom(s), (cy, wy) = catmullRom(t)
                        var r: Float = 0, g: Float = 0, b: Float = 0
                        for j in 0..<4 {
                            let nodeRow = min(max(cy - 1 + j, 0), 2) * 3
                            for i in 0..<4 {
                                let weight = wy[j] * wx[i]
                                let n = (nodeRow + min(max(cx - 1 + i, 0), 2)) * 3
                                r += weight * node[n]; g += weight * node[n + 1]; b += weight * node[n + 2]
                            }
                        }
                        let at = (y * width + x) * 4
                        out[at] = UInt8(min(max(r, 0), 1) * 255 + 0.5)
                        out[at + 1] = UInt8(min(max(g, 0), 1) * 255 + 0.5)
                        out[at + 2] = UInt8(min(max(b, 0), 1) * 255 + 0.5)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The cell (0 or 1) of a position in 0...2, and the weights of the four nodes around it.
    private nonisolated static func catmullRom(_ position: Float) -> (cell: Int, weights: SIMD4<Float>) {
        let cell = min(Int(position), 1)
        let t = position - Float(cell), t2 = t * t, t3 = t2 * t
        return (cell, SIMD4(0.5 * (-t3 + 2 * t2 - t), 0.5 * (3 * t3 - 5 * t2 + 2),
                            0.5 * (-3 * t3 + 4 * t2 + t), 0.5 * (t3 - t2)))
    }
}

/// What "Resa dello sfondo" does at a slider position (Settings > Aspetto), in steps of 0.1:
/// - 0: the static bitmap, only drifting (Core Animation, no app code per frame).
/// - 0.1...0.9: the mesh points really move (the original's motion), painted off the main
///   thread into a bitmap and crossfaded by Core Animation; more updates per second and a
///   bigger bitmap the higher it is.
/// - 1: the original, a full-screen MeshGradient redrawn 10 times a second.
struct AlbumBackdropProfile: Equatable {
    /// 0...10.
    let step: Int

    init(quality: Double) { step = min(max(Int((quality * 10).rounded()), 0), 10) }

    var isOriginal: Bool { step == 10 }
    /// Bitmap repaints per second; 0 = never (static picture).
    var updatesPerSecond: Double {
        guard step > 0 && step < 10 else { return step == 10 ? 10 : 0 }
        return [0.5, 1, 2, 3, 4, 5, 6, 8, 10][step - 1]
    }
    var bitmapWidth: Int { step == 0 ? MeshBitmap.width : 40 + 8 * step }
    var bitmapHeight: Int { bitmapWidth * 2 }
}

/// Where the slider's value is stored. Replaces the old two-way picker (`albumColorBackgroundRenderer`:
/// "bitmap" = 0, "mesh" = 1), migrated once.
enum AlbumBackdropQuality {
    static let storageKey = "albumColorBackgroundQuality"
    private static let legacyKey = "albumColorBackgroundRenderer"

    /// The @AppStorage default: 0, or what the old picker had, moved to the new key (once).
    static let initial: Double = {
        let defaults = UserDefaults.standard
        if let old = defaults.string(forKey: legacyKey) {
            if defaults.object(forKey: storageKey) == nil {
                defaults.set(old == "mesh" ? 1.0 : 0.0, forKey: storageKey)
            }
            defaults.removeObject(forKey: legacyKey)
        }
        return 0
    }()
}

/// How long the last repaints took, for the readout under the slider. Plain numbers, no
/// observation: the readout polls it once a second.
@MainActor
final class BackdropStats {
    static let shared = BackdropStats()
    /// Moving average of a bitmap repaint, in milliseconds; 0 until one is done.
    private(set) var repaintMs = 0.0

    func record(_ ms: Double) { repaintMs = repaintMs == 0 ? ms : repaintMs * 0.8 + ms * 0.2 }
    func reset() { repaintMs = 0 }
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
    let profile: AlbumBackdropProfile
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
                DriftingPicture(image: image, nodes: palette.nodes, profile: profile,
                                opacity: colorScheme == .dark ? 0.5 : 0.36, drifts: drifts, motion: motion)
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
    let nodes: [Float]
    let profile: AlbumBackdropProfile
    /// How much of the picture shows over the page color: a pastel wash in light mode, a
    /// dim glow in dark mode.
    let opacity: Float
    let drifts: Bool
    let motion: BackdropMotion

    init(image: CGImage, nodes: [Float], profile: AlbumBackdropProfile, opacity: Double, drifts: Bool, motion: BackdropMotion) {
        self.image = image
        self.nodes = nodes
        self.profile = profile
        self.opacity = Float(opacity)
        self.drifts = drifts
        self.motion = motion
    }

    func makeUIView(context: Context) -> DriftView {
        let view = DriftView(image: image, nodes: nodes, opacity: opacity)
        view.profile = profile
        view.allowsDrift = drifts
        view.motion = motion
        motion.register(view)
        return view
    }

    func updateUIView(_ view: DriftView, context: Context) {
        view.setOpacity(opacity)
        view.profile = profile
        view.allowsDrift = drifts
    }
}

/// The picture on a layer larger than the screen, moved by two Core Animations that run in the
/// render server (an orbit and a slight turn, 36 s and 47 s a cycle, at a low frame rate): the
/// app does nothing per frame. Pausing freezes the layer where it is. With a profile that moves
/// the mesh, a task also repaints the bitmap off the main thread a few times a second and
/// swaps it in with a crossfade, so low rates still look smooth.
final class DriftView: UIView {
    private let picture = CALayer()
    private let staticImage: CGImage
    private let nodes: [Float]
    weak var motion: BackdropMotion?
    var allowsDrift = false { didSet { refresh() } }
    var profile = AlbumBackdropProfile(quality: 0) {
        didSet {
            guard profile != oldValue else { return }
            stopRepainting()
            if profile.updatesPerSecond == 0 { picture.contents = staticImage }
            BackdropStats.shared.reset()
            refresh()
        }
    }
    private var running = false
    private var repaint: Task<Void, Never>?
    private var laidOutSize: CGSize = .zero

    init(image: CGImage, nodes: [Float], opacity: Float) {
        staticImage = image
        self.nodes = nodes
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Off screen (album changed, tab gone): no repainting for a view nobody sees.
        if window == nil { stopRepainting() } else { refresh() }
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
        let shouldRun = allowsDrift && !(motion?.scrolling ?? false) && window != nil
            && picture.animation(forKey: "orbit") != nil
        if shouldRun != running {
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
        // The bitmap is repainted under the same conditions as the drift.
        if shouldRun && profile.updatesPerSecond > 0 {
            if repaint == nil { startRepainting() }
        } else {
            stopRepainting()
        }
    }

    private func stopRepainting() {
        repaint?.cancel()
        repaint = nil
    }

    /// One repaint after the other: the mesh points as they will be when the crossfade ends,
    /// painted off the main thread; the main thread only swaps the picture in. The loop holds
    /// the view weakly, so it can't keep it alive.
    private func startRepainting() {
        let profile = profile, nodes = nodes
        let interval = 1 / profile.updatesPerSecond
        repaint = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let started = CACurrentMediaTime()
                let time = Date.timeIntervalSinceReferenceDate + interval
                let made = await Task.detached(priority: .utility) { () -> CGImage? in
                    MeshBitmap.render(nodes: nodes, points: LegacyAlbumMesh.points(at: time),
                                      width: profile.bitmapWidth, height: profile.bitmapHeight)
                }.value
                guard !Task.isCancelled, let self else { return }
                let spent = CACurrentMediaTime() - started
                if let made {
                    BackdropStats.shared.record(spent * 1000)
                    self.show(made, fading: interval, rate: profile.updatesPerSecond)
                }
                try? await Task.sleep(for: .seconds(max(0.02, interval - spent)))
            }
        }
    }

    private func show(_ image: CGImage, fading duration: TimeInterval, rate: Double) {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        fade.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 30, preferred: Float(min(30, max(12, rate * 2))))
        picture.add(fade, forKey: "fade")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        CATransaction.commit()
    }
}

/// What the chosen level costs, under the slider: updates per second, bitmap size and the
/// measured repaint time. Polls the stats once a second; nothing runs per frame.
struct AlbumBackdropReadout: View {
    let quality: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var text: String {
        let profile = AlbumBackdropProfile(quality: quality)
        let rate = profile.updatesPerSecond.formatted(.number.precision(.fractionLength(0...1)))
        if profile.isOriginal { return "\(rate) aggiornamenti/s · mesh a schermo intero" }
        if profile.updatesPerSecond == 0 { return "Nessun aggiornamento · bitmap \(profile.bitmapWidth)×\(profile.bitmapHeight), solo deriva" }
        let ms = BackdropStats.shared.repaintMs
        let cost = ms > 0 ? " · \(ms.formatted(.number.precision(.fractionLength(1)))) ms a disegno" : ""
        return "≈ \(rate) aggiornamenti/s · bitmap \(profile.bitmapWidth)×\(profile.bitmapHeight)\(cost)"
    }
}

/// A small live sample of the background, for the slider's row in Settings.
struct AlbumBackdropPreview: View {
    let quality: Double
    @State private var motion = BackdropMotion()

    var body: some View {
        let profile = AlbumBackdropProfile(quality: quality)
        Group {
            if profile.isOriginal {
                LegacyAlbumColorBackground()
            } else {
                AlbumColorBackground(motion: motion, profile: profile)
            }
        }
        .frame(height: 96)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
#endif

// MARK: - Applying it

private struct AlbumColorBackgroundModifier: ViewModifier {
    @AppStorage(AlbumBackdrop.storageKey) private var enabled = false
    @AppStorage(AlbumBackdropQuality.storageKey) private var quality = AlbumBackdropQuality.initial
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
                .background {
                    let profile = AlbumBackdropProfile(quality: quality)
                    if profile.isOriginal {
                        LegacyAlbumColorBackground()
                    } else {
                        AlbumColorBackground(motion: motion, profile: profile)
                    }
                }
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
