// LandscapeCoverFlow.swift
// Full-screen Cover Flow of the library's albums, shown when the iPhone is turned sideways
// (Settings → "Cover Flow in orizzontale"): the current cover big in the middle, the next
// albums as a row of spines on its right and the previous ones mirrored on its left.
// A tap on the cover slides the vinyl out of the sleeve and plays the album.

#if os(iOS)
import SwiftUI
import Combine

// MARK: - Geometry

/// All the layout numbers. `d` is an album's distance from the current position, in albums
/// (0 = the big cover, ±1 = the first spine on either side…). The row is symmetric: the cover
/// sits in the middle and the spines spread out to the edges of the content area.
private struct Layout: Equatable {
    /// Spine rotation. Right spines pivot on their right edge and the left ones on their left
    /// edge, so the visible slice is always the edge nearest to the viewer.
    static let spineAngle: Double = 72
    static let rightSign: Double = -1
    static let perspective: CGFloat = 0.4
    /// Spines shown on each side of the cover.
    static let spinesPerSide = 8
    /// Space between the cover and the first spine.
    static let gap: CGFloat = 14
    /// Space between the sleeve and the record once it is out.
    static let pairGap: CGFloat = 32

    let width: CGFloat
    let height: CGFloat

    var side: CGFloat { min(300, height * 0.83) }
    /// The cover is centered.
    var lead: CGFloat { (width - side) / 2 }
    /// The outermost spine ends exactly at the content edge.
    var pitch: CGFloat { max(((width - side) / 2 - Self.gap) / CGFloat(Self.spinesPerSide), 12) }
    /// How far a finger travels to move by one album.
    var pointsPerAlbum: CGFloat { max(pitch * 1.5, 30) }
    var diameter: CGFloat { side * 0.9 }
    /// With the record out, cover and record are centered as a group.
    var openLead: CGFloat { (width - (side + Self.pairGap + diameter)) / 2 }
    var recordOutX: CGFloat { openLead + side + Self.pairGap }
    /// The record's place behind the closed cover.
    var recordRestX: CGFloat { lead + (side - diameter) / 2 }

    /// Distance of a pivot edge from the cover's edge, for `a` = |d|: the first step is a
    /// little longer (the gap), then one pitch per album.
    private func run(_ a: Double) -> CGFloat {
        a <= 1 ? (Self.gap + pitch) * CGFloat(a) : Self.gap + pitch * CGFloat(a)
    }

    /// Left edge of the album's view, in content coordinates.
    func leadingX(d: Double) -> CGFloat {
        d >= 0 ? lead + run(d) : lead - run(-d)
    }

    /// Which album a tap at `x` lands on, as an offset from the current one (0 = the cover).
    func albumOffset(atX x: CGFloat, coverLead: CGFloat) -> Int {
        if x >= coverLead && x <= coverLead + side { return 0 }
        let distance = x > coverLead + side ? x - (coverLead + side) : coverLead - x
        let k = max(1, Int(((distance - Self.gap) / pitch).rounded(.up)))
        return x > coverLead ? k : -k
    }
}

private struct Slot: Identifiable {
    let index: Int
    let album: AlbumItem
    var id: String { album.Id }
}

// MARK: - Stage

/// The covers. It is `Animatable` on the position so that, while a fling or a tap animates
/// the position, SwiftUI re-runs this body every frame with the in-between value and each
/// cover follows a true path (a plain animation would just interpolate each modifier).
private struct CoverFlowStage: View, Animatable {
    var position: Double
    let albums: [AlbumItem]
    let layout: Layout
    let isOpen: Bool
    let artwork: (String) -> URL?
    let onActivate: (Int) -> Void

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    private var window: [Slot] {
        guard !albums.isEmpty else { return [] }
        // One more than the spines shown, so the last one fades out instead of popping.
        let reach = Layout.spinesPerSide + 2
        let lo = max(0, Int(position.rounded(.down)) - reach)
        let hi = min(albums.count - 1, Int(position.rounded(.up)) + reach)
        guard lo <= hi else { return [] }
        return (lo...hi).map { Slot(index: $0, album: albums[$0]) }
    }

    var body: some View {
        let nearest = Int(position.rounded())
        ZStack(alignment: .topLeading) {
            ForEach(window) { slot in
                cover(slot, isCurrent: slot.index == nearest)
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .sensoryFeedback(.selection, trigger: nearest)
    }

    private func cover(_ slot: Slot, isCurrent: Bool) -> some View {
        let d = Double(slot.index) - position
        let t = min(abs(d), 1)
        let side = layout.side
        let angle = (d >= 0 ? Layout.rightSign : -Layout.rightSign) * Layout.spineAngle * t
        let x = layout.leadingX(d: d)
        // Full strength up to the last spine, gone one album after.
        let fade = min(max(Double(Layout.spinesPerSide) + 1 - abs(d), 0), 1)
        let hidden = isOpen && abs(d) > 0.5
        // With the record out the cover steps left; the spines drift away on their side.
        let shift: CGFloat = !isOpen ? 0 : (abs(d) <= 0.5 ? layout.openLead - layout.lead : (d > 0 ? 36 : -36))

        return CachedAsyncImage(url: artwork(slot.album.Id), targetSize: side) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(Color.gray.opacity(0.35))
        }
        .frame(width: side, height: side)
        .clipped()
        .overlay { Color.black.opacity(0.3 * t) }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        // The sleeve's thin light edge.
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 1.2)
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0),
                          anchor: d >= 0 ? .trailing : .leading, perspective: Layout.perspective)
        .shadow(color: .black.opacity(0.28), radius: 9, x: 0, y: 4)
        .offset(x: x + shift, y: (layout.height - side) / 2)
        .opacity(hidden ? 0 : fade)
        .animation(.soft(0.4), value: isOpen)
        .zIndex(100 - abs(d))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(for: slot.album, isCurrent: isCurrent))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onActivate(slot.index) }
    }

    private func label(for album: AlbumItem, isCurrent: Bool) -> String {
        let name = [album.Name, album.AlbumArtist].compactMap { $0 }.joined(separator: ", ")
        return isCurrent ? "Copertina: \(name). Tocca per ascoltare" : "Album: \(name)"
    }
}

// MARK: - Vinyl

/// The record: a colored disc with grooves, a static sheen and the cover as its label.
/// It spins slowly while `spinning`, and keeps its angle when it stops.
private struct VinylDisc: View {
    let diameter: CGFloat
    let color: Color
    let coverURL: URL?
    let spinning: Bool
    /// The song is still being fetched: a small spinner over the spindle.
    var loading = false

    @State private var baseAngle = 0.0
    @State private var spinningSince: Date?

    private let degreesPerSecond = 24.0

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: spinningSince == nil)) { context in
                let extra = spinningSince.map { context.date.timeIntervalSince($0) * degreesPerSecond } ?? 0
                disc.rotationEffect(.degrees(baseAngle + extra))
            }
            // The light doesn't turn with the record.
            Circle()
                .fill(AngularGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.26), location: 0.07),
                    .init(color: .clear, location: 0.16),
                    .init(color: .clear, location: 0.5),
                    .init(color: .white.opacity(0.26), location: 0.57),
                    .init(color: .clear, location: 0.66),
                    .init(color: .clear, location: 1)
                ], center: .center, angle: .degrees(20)))
                .mask {
                    // Only on the grooved ring, not over the label.
                    Circle().strokeBorder(Color.white, lineWidth: diameter * 0.33)
                }
                .allowsHitTesting(false)
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .padding(7)
                    .background(.ultraThinMaterial, in: Circle())
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: loading)
        .frame(width: diameter, height: diameter)
        .shadow(color: .black.opacity(0.3), radius: 10, x: 2, y: 5)
        .onChange(of: spinning, initial: true) { _, on in
            if on {
                if spinningSince == nil { spinningSince = .now }
            } else if let since = spinningSince {
                baseAngle = (baseAngle + Date.now.timeIntervalSince(since) * degreesPerSecond)
                    .truncatingRemainder(dividingBy: 360)
                spinningSince = nil
            }
        }
    }

    private var disc: some View {
        let labelSize = diameter * 0.35
        return ZStack {
            // Slightly translucent, like colored vinyl.
            Circle().fill(color.opacity(0.9))
            Circle().fill(RadialGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.14)],
                                         center: .center, startRadius: 0, endRadius: diameter / 2))
            // A few thin rings between the label and the rim.
            ForEach(0..<8, id: \.self) { ring in
                let inset = diameter * (0.045 + 0.034 * CGFloat(ring))
                Circle()
                    .inset(by: inset)
                    .stroke(ring.isMultiple(of: 2) ? Color.black.opacity(0.13) : Color.white.opacity(0.1),
                            lineWidth: 0.7)
            }
            Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)

            CachedAsyncImage(url: coverURL, targetSize: labelSize) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.gray.opacity(0.4)
            }
            .frame(width: labelSize, height: labelSize)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.8) }

            // Spindle hole.
            Circle()
                .fill(Color(white: 0.93))
                .frame(width: diameter * 0.045, height: diameter * 0.045)
                .overlay { Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5) }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - View

struct LandscapeCoverFlow: View {
    @EnvironmentObject private var viewModel: JellyfinViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("albumsSort") private var sort: AlbumsView.AlbumSort = .title
    @AppStorage(CoverFlowSettings.resumeKey) private var resumesPlaying = true

    /// Sorted once per change, like the Albums tab: the albums are thousands.
    @State private var albums: [AlbumItem] = []
    /// Continuous position in albums; whole numbers are at rest on an album.
    @State private var position = 0.0
    @State private var dragStart: Double?

    /// The album whose vinyl is out (or sliding back in), and where it sits.
    @State private var vinylAlbum: AlbumItem?
    @State private var vinylOut = false
    @State private var vinylVisible = false
    /// Album id the vinyl is "open" for; nil when browsing.
    @State private var openedId: String?
    /// The resume (disc out on the playing album) happens once per appearance.
    @State private var resumeHandled = false
    /// The songs of this album are being asked to the server.
    @State private var fetchingAlbumId: String?
    /// The player is downloading the current song (nothing audible yet).
    @State private var audioLoading = false

    @State private var backdrop: Backdrop?
    @State private var previousBackdrop: Backdrop?
    @State private var palette = HeroPalette.neutral

    struct Backdrop: Equatable {
        let id: String
        let image: PlatformImage
    }

    init() {}

    // MARK: Derived

    private var centerIndex: Int {
        guard !albums.isEmpty else { return 0 }
        return min(max(Int(position.rounded()), 0), albums.count - 1)
    }

    private var currentAlbum: AlbumItem? {
        albums.indices.contains(centerIndex) ? albums[centerIndex] : nil
    }

    private var loadKey: String {
        "\(sort.rawValue)|\(viewModel.albums.count)|\(viewModel.albums.first?.Id ?? "")|\(viewModel.albums.last?.Id ?? "")"
    }

    private func isPlayingAlbum(_ album: AlbumItem) -> Bool {
        viewModel.currentlyPlayingItem?.AlbumId == album.Id
    }

    private var loadingPublisher: AnyPublisher<Bool, Never> {
        viewModel.playerManager?.$isLoading.removeDuplicates().eraseToAnyPublisher()
            ?? Empty().eraseToAnyPublisher()
    }

    /// Fetching the songs or downloading the first one: nothing to pause yet.
    private func isAlbumLoading(_ album: AlbumItem) -> Bool {
        fetchingAlbumId == album.Id || (isPlayingAlbum(album) && audioLoading)
    }

    private func anim(_ animation: Animation) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : animation
    }

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width - 124
            let height = geo.size.height - 40
            ZStack {
                backdropLayer(size: geo.size)
                content(width: width, height: height)
                    .frame(width: width, height: height)
                    .padding(.horizontal, 62)
                    .padding(.vertical, 20)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .task(id: loadKey) { await reload() }
        .task(id: currentAlbum?.Id) { await loadBackdrop() }
        .onReceive(loadingPublisher) { audioLoading = $0 }
        .onChange(of: currentAlbum?.Id) { _, new in
            if let opened = openedId, opened != new { closeVinyl() }
        }
    }

    @ViewBuilder
    private func content(width: CGFloat, height: CGFloat) -> some View {
        let layout = Layout(width: width, height: height)
        if albums.isEmpty {
            ProgressView().frame(width: width, height: height)
        } else {
            ZStack(alignment: .topLeading) {
                if let vinylAlbum {
                    vinyl(for: vinylAlbum, layout: layout)
                }
                CoverFlowStage(position: position, albums: albums, layout: layout,
                               isOpen: openedId != nil,
                               artwork: { viewModel.artworkURL(for: $0, size: 600) },
                               onActivate: { activate($0) })
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(drag(layout))
        }
    }

    // MARK: Background

    private func backdropLayer(size: CGSize) -> some View {
        ZStack {
            Color(.systemBackground)
            if let previousBackdrop {
                blurred(previousBackdrop, size: size)
            }
            if let backdrop {
                blurred(backdrop, size: size)
                    .id(backdrop.id)
                    .transition(.opacity)
            }
            // Washed out: light in light mode, dark in dark mode.
            (colorScheme == .dark ? Color.black.opacity(0.55) : Color.white.opacity(0.58))
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.5), value: backdrop?.id)
        .accessibilityHidden(true)
    }

    private func blurred(_ item: Backdrop, size: CGSize) -> some View {
        Image(platformImage: item.image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
            .blur(radius: 38, opaque: true)
    }

    // MARK: Vinyl

    private func vinyl(for album: AlbumItem, layout: Layout) -> some View {
        let diameter = layout.diameter
        let height = layout.height
        let restX = layout.recordRestX
        let outX = layout.recordOutX
        let spinning = vinylOut && !reduceMotion && viewModel.isPlaying && isPlayingAlbum(album)
        let state = isPlayingAlbum(album) ? (viewModel.isPlaying ? "in riproduzione" : "in pausa") : "ferma"
        return ZStack(alignment: .topLeading) {
            VinylDisc(diameter: diameter, color: palette.background,
                      coverURL: viewModel.artworkURL(for: album.Id, size: 300), spinning: spinning,
                      loading: isAlbumLoading(album))
                .offset(x: restX, y: (height - diameter) / 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Disco in vinile di \(album.Name), \(state)")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggleVinylPlayback(album) }

            VStack(spacing: 2) {
                Text(album.Name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let artist = album.AlbumArtist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: diameter)
            .offset(x: restX, y: (height + diameter) / 2 + 6)
            .opacity(vinylOut ? 1 : 0)
            .accessibilityHidden(true)
        }
        // The slide is one offset on the whole group: the disc starts centered behind the cover.
        .offset(x: vinylOut ? outX - restX : 0)
        .animation(vinylOut ? anim(.springy(0.8)) : anim(.soft(0.45)), value: vinylOut)
        .opacity(vinylVisible ? 1 : 0)
    }

    private func openVinyl(_ album: AlbumItem) {
        vinylAlbum = album
        vinylVisible = true
        withAnimation(anim(.soft(0.4))) { openedId = album.Id }
        Task {
            // One beat with the disc behind the cover, then it slides out.
            try? await Task.sleep(for: .milliseconds(30))
            vinylOut = true
        }
        playOrResume(album)
    }

    /// The album page's Play button: the album is started from its first song, unless it
    /// is the one already loaded, which is only resumed if paused.
    private func playOrResume(_ album: AlbumItem) {
        if isPlayingAlbum(album) {
            if !viewModel.isPlaying { viewModel.playerManager.play() }
        } else {
            startAlbum(album)
        }
    }

    private func startAlbum(_ album: AlbumItem) {
        let player = viewModel.playerManager
        guard fetchingAlbumId != album.Id else { return }
        fetchingAlbumId = album.Id
        Task {
            let tracks = await viewModel.fetchAlbumTracksDirectly(albumId: album.Id)
            fetchingAlbumId = nil
            guard let first = tracks.first else {
                print("[CoverFlow] \(album.Name): the server returned no songs, nothing to play")
                return
            }
            player?.play(item: first, in: tracks)
        }
    }

    private func closeVinyl() {
        guard openedId != nil || vinylAlbum != nil else { return }
        withAnimation(anim(.soft(0.4))) { openedId = nil }
        vinylOut = false
        // It slides back behind the cover and fades, for when the cover has moved on.
        withAnimation(.easeIn(duration: 0.35).delay(0.15)) { vinylVisible = false }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !vinylOut { vinylAlbum = nil }
        }
    }

    /// The record: pause or play, like the album page's button.
    private func toggleVinylPlayback(_ album: AlbumItem) {
        // Still loading: isPlaying is already true, a tap would pause what hasn't started.
        guard !isAlbumLoading(album) else { return }
        if isPlayingAlbum(album) {
            if viewModel.isPlaying { viewModel.playerManager.pause() } else { viewModel.playerManager.play() }
        } else {
            startAlbum(album)
        }
    }

    // MARK: Gestures

    private func drag(_ layout: Layout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width
                guard abs(dx) > 8 || dragStart != nil else { return }
                if dragStart == nil { dragStart = position }
                if openedId != nil { closeVinyl() }
                let next = min(max((dragStart ?? position) - Double(dx / layout.pointsPerAlbum), 0),
                               Double(max(albums.count - 1, 0)))
                if next != position { position = next }
            }
            .onEnded { value in
                defer { dragStart = nil }
                guard dragStart != nil else {
                    tap(at: value.location, layout: layout)
                    return
                }
                // Momentum: the release velocity carries on for a fraction of a second.
                let carried = Double(value.velocity.width) * 0.18 / Double(layout.pointsPerAlbum)
                let target = min(max((position - carried).rounded(), 0), Double(max(albums.count - 1, 0)))
                let distance = abs(target - position)
                withAnimation(anim(.soft(0.35 + min(0.55, distance * 0.05)))) { position = target }
            }
    }

    private func tap(at point: CGPoint, layout: Layout) {
        guard let album = currentAlbum else { return }
        if openedId != nil {
            // Record out: cover on the left of the pair, disc on its right.
            let diameter = layout.diameter
            let center = CGPoint(x: layout.recordOutX + diameter / 2, y: layout.height / 2)
            if hypot(point.x - center.x, point.y - center.y) <= diameter / 2 {
                toggleVinylPlayback(album)
            } else if layout.albumOffset(atX: point.x, coverLead: layout.openLead) == 0 {
                closeVinyl()
            }
            return
        }
        let offset = layout.albumOffset(atX: point.x, coverLead: layout.lead)
        if offset == 0 {
            openVinyl(album)
        } else {
            jump(to: centerIndex + offset)
        }
    }

    private func jump(to index: Int) {
        let target = min(max(index, 0), albums.count - 1)
        let distance = abs(Double(target) - position)
        withAnimation(anim(.soft(0.4 + min(0.4, distance * 0.05)))) { position = Double(target) }
    }

    /// From VoiceOver: the cover opens the vinyl, any other element jumps to its album.
    private func activate(_ index: Int) {
        if index == centerIndex {
            if openedId != nil { closeVinyl() } else if let album = currentAlbum { openVinyl(album) }
        } else {
            jump(to: index)
        }
    }

    // MARK: Loading

    private func reload() async {
        let source = viewModel.albums
        let order = sort
        let sorted = await Task.detached(priority: .userInitiated) { Self.sorted(source, by: order) }.value
        guard !Task.isCancelled else { return }
        // Keep the album that was in front; at the start, the one playing.
        let anchor = openedId ?? currentAlbum?.Id ?? viewModel.currentlyPlayingItem?.AlbumId
        let start = anchor.flatMap { id in sorted.firstIndex { $0.Id == id } } ?? 0
        // Everything in one update, so the stage first appears already in its final state:
        // no scrub, no disc sliding out.
        albums = sorted
        position = Double(start)
        resumeIfPlaying(in: sorted)
    }

    /// Back in landscape with music on: the playing album in front, disc out, playback untouched.
    private func resumeIfPlaying(in sorted: [AlbumItem]) {
        guard !resumeHandled, !sorted.isEmpty else { return }
        resumeHandled = true
        guard resumesPlaying, viewModel.isPlaying,
              let albumId = viewModel.currentlyPlayingItem?.AlbumId,
              let found = sorted.firstIndex(where: { $0.Id == albumId }) else { return }
        position = Double(found)
        vinylAlbum = sorted[found]
        vinylVisible = true
        vinylOut = true
        openedId = albumId
    }

    /// The same order as the Albums tab.
    private nonisolated static func sorted(_ albums: [AlbumItem], by sort: AlbumsView.AlbumSort) -> [AlbumItem] {
        let ordered: [AlbumItem]
        switch sort {
        case .added:
            return albums
        case .title:
            ordered = albums.sorted { $0.Name.localizedStandardCompare($1.Name) == .orderedAscending }
        case .artist:
            ordered = albums.sorted { a, b in
                let byArtist = (a.AlbumArtist ?? "").localizedStandardCompare(b.AlbumArtist ?? "")
                if byArtist != .orderedSame { return byArtist == .orderedAscending }
                return (a.ProductionYear ?? 0) < (b.ProductionYear ?? 0)
            }
        }
        let name: (AlbumItem) -> String = sort == .title ? { $0.Name } : { $0.AlbumArtist ?? "" }
        return LetterIndex.sections(ordered, name: name).flatMap(\.items)
    }

    /// The blurred background and the vinyl's color follow the front album. The short wait
    /// keeps a fast scrub from loading every cover it passes.
    private func loadBackdrop() async {
        guard let album = currentAlbum else { return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled,
              let url = viewModel.artworkURL(for: album.Id, size: 600),
              let image = await ImageLoader.shared.firstImage(from: [url]),
              !Task.isCancelled else { return }
        let colors = HeroPalette(image: image)
        previousBackdrop = backdrop
        backdrop = Backdrop(id: album.Id, image: image)
        if let colors {
            withAnimation(.easeInOut(duration: 0.4)) { palette = colors }
        }
    }
}
#endif
