import SwiftUI
#if os(iOS)
import MediaPlayer
import AVFoundation
#endif

/// Full-screen expanded Now Playing view (iOS only).
/// Displayed inline in ContentView. Its Liquid Glass elements use the
/// `.materialize` transition (not `.matchedGeometry`): the mini player bar
/// is a single small capsule, while this view is a full-screen composition of
/// several separate glass shapes — per Apple's guidance, `matchedGeometry` is
/// meant for shapes within a container's spacing threshold, and `materialize`
/// for effects that are added/removed farther apart than that.
///
/// Layering rule (HIG): glass lives in the chrome, never stacked on itself.
/// This view therefore has exactly three glass surfaces — the track info plate,
/// the transport capsule, and the audio-info row — and never one inside another.
/// The play button sits *inside* the transport capsule as a plain tinted circle
/// rather than its own glass shape, so the material is only sampled once.
struct NowPlayingFullView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    let item: AudioItem
    let isPlaying: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let artworkURL: URL?

    let onPlayPause: () -> Void
    let onBackward: () -> Void
    let onForward: () -> Void
    let onSeek: (TimeInterval) -> Void

    @Binding var isExpanded: Bool
    var artworkNamespace: Namespace.ID? = nil

    @ObservedObject private var colorManager = AccentColorManager.shared
    @State private var avgColor: Color = .clear

    /// Intensity is user-adjustable in Settings (Liquid Glass → Intensità colore).
    /// On iOS 27 the system exposes its own Liquid Glass intensity slider that the
    /// material follows automatically — keep this as a per-app override, not the only lever.
    private var playButtonTint: Color {
        guard colorManager.glassTintEnabled else { return .accentColor }
        return avgColor.opacity(colorManager.glassTintIntensity)
    }
    @State private var sliderValue: Double = 0
    @State private var isEditingSlider: Bool = false
    @State private var dragOffset: CGFloat = 0
    @State private var showAudioInfo: Bool = false
    @State private var panel: PlayerPanel = .artwork
    @State private var showTrackInfo = false
    /// Page color and text color from the cover, as on the album pages.
    @State private var palette = HeroPalette.neutral
    private var fg: Color { palette.foreground }
    #if os(iOS)
    @ObservedObject private var systemVolume = SystemVolume.shared
    #endif

    /// Volume is temporarily hidden per product decision — flip this back to `true` to restore it.
    private let isVolumeSliderEnabled = false

    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // One color taken from the cover's bottom edge (as on the album pages),
                // a little deeper towards the bottom.
                ZStack {
                    palette.background
                    LinearGradient(colors: [.clear, .black.opacity(palette.isLight ? 0.08 : 0.25)],
                                   startPoint: .center, endPoint: .bottom)
                }
                .animation(.easeInOut(duration: 0.6), value: palette)

                appleMusicLayout(geo)
            }
            .offset(y: dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if value.translation.height > 0 {
                            dragOffset = value.translation.height
                        }
                    }
                    .onEnded { value in
                        if value.translation.height > 100 || value.predictedEndTranslation.height > 300 {
                            // Keep the drag offset: springing it back to 0 while the view slides
                            // away made it jump up at the end of the close.
                            withAnimation(.spring(response: 0.45, dampingFraction: 0.9)) {
                                isExpanded = false
                            }
                            return
                        }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragOffset = 0
                        }
                    }
            )
        }
        .ignoresSafeArea()
        .onChange(of: currentTime) {
            if !isEditingSlider {
                sliderValue = currentTime
            }
        }
        .task(id: artworkURL) {
            await loadAverageColor(url: artworkURL)
        }
        .task(id: item.AlbumId ?? item.id) {
            guard let url = viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 1200),
                  let image = await ImageLoader.shared.firstImage(from: [url]),
                  let colors = HeroPalette(image: image) else { return }
            palette = colors
        }
        #if DEBUG
        // Test-only: `-provaPannello lyrics|queue` opens the player on that panel.
        .onAppear {
            switch UserDefaults.standard.string(forKey: "provaPannello") {
            case "lyrics": panel = .lyrics
            case "queue": panel = .queue
            default: break
            }
        }
        #endif
        // Audio details live in a sheet, not in an expanding glass plate: the numbers
        // sit on an opaque background where they stay legible, and the player's glass
        // row never changes height.
        .sheet(isPresented: $showTrackInfo) {
            ItemInfoSheet(itemId: item.Id, kind: .track, title: item.Name)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showAudioInfo) {
            AudioInfoSheet(playerManager: viewModel.playerManager!)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private func loadAverageColor(url: URL?) async {
        guard let url else { avgColor = .clear; return }
        let color = await Task.detached(priority: .utility) { () -> Color? in
            ImageCacheService.shared.getImage(forKey: ImageCacheService.shared.key(for: url))?.averageColor()
        }.value
        if let color { avgColor = color }
    }

    // MARK: - Apple Music layout

    /// What fills the top of the Apple Music layout.
    enum PlayerPanel { case artwork, lyrics, queue }

    /// Apple Music on iOS 26: the cover edge to edge at the top, fading into its own
    /// blurred colors; title and artist with star and "⋯"; thick scrubber with the
    /// remaining time and the format; bare transport glyphs; volume; lyrics · output · queue.
    private func appleMusicLayout(_ geo: GeometryProxy) -> some View {
        let width = geo.size.width
        let showingArtwork = panel == .artwork

        return ZStack(alignment: .top) {
            // Full-bleed cover, fading out downwards. Hidden behind lyrics and queue.
            CachedAsyncImage(url: viewModel.artworkURL(for: item.AlbumId ?? item.id, size: 1200), targetSize: width,
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: { Color.clear }
            )
            .id(item.AlbumId ?? item.id)
            .frame(width: width, height: width)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .playerArtwork(in: artworkNamespace)
            // Edge to edge it stays put when paused: shrinking would open gaps at the sides.
            .opacity(showingArtwork ? 1 : 0)
            .animation(.easeInOut(duration: 0.35), value: panel)


            VStack(spacing: 0) {
                Capsule()
                    .fill(fg.opacity(0.5))
                    .frame(width: 36, height: 5)
                    .padding(.top, max(geo.safeAreaInsets.top, 59) + 6)

                Group {
                    switch panel {
                    case .artwork:
                        Spacer(minLength: 0)
                    case .lyrics:
                        LyricsPanel(item: item, currentTime: currentTime, color: fg, onSeek: onSeek)
                    case .queue:
                        QueuePanel(color: fg)
                    }
                }
                .frame(maxHeight: .infinity)
                .transition(.opacity)

                titleRow
                    .padding(.horizontal, 32)
                    .padding(.top, 14)

                appleScrubber
                    .padding(.horizontal, 32)
                    .padding(.top, 20)

                transportRow
                    .padding(.top, 22)

                #if os(iOS)
                volumeRow
                    .padding(.horizontal, 32)
                    .padding(.top, 26)
                #endif

                bottomRow
                    .padding(.horizontal, 44)
                    .padding(.top, 24)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 34) + 4)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: panel)
        // Glass buttons and menus follow the page: light on light covers, dark on dark.
        .environment(\.colorScheme, palette.isLight ? .light : .dark)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.Name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                // Tap the artist to open their page, as in Apple Music.
                Button {
                    if let artist = viewModel.artistItem(for: item) {
                        LibraryNavigator.shared.show(.artist(artist))
                    }
                } label: {
                    Text(viewModel.artistName(for: item) ?? "")
                        .font(.title3)
                        .foregroundStyle(fg.opacity(0.75))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Apre la pagina dell'artista")
            }
            Spacer(minLength: 8)

            Button {
                viewModel.toggleFavoriteTrack(item.id)
            } label: {
                Image(systemName: viewModel.isTrackFavorite(item.id) ? "star.fill" : "star")
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: viewModel.isTrackFavorite(item.id))
                    .foregroundStyle(fg)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isTrackFavorite(item.id) ? "Rimuovi dai preferiti" : "Aggiungi ai preferiti")

            Menu {
                Button {
                    showTrackInfo = true
                } label: {
                    Label("Info brano", systemImage: "music.note")
                }
                Button {
                    viewModel.playerManager.refreshAudioOutputInfo()
                    showAudioInfo = true
                } label: {
                    Label("Info audio", systemImage: "waveform")
                }
                Button {
                    viewModel.playerManager.toggleShuffle()
                } label: {
                    Label(viewModel.playerManager.isShuffled ? "Casuale: attivo" : "Casuale",
                          systemImage: "shuffle")
                }
                Button {
                    viewModel.toggleRepeatMode()
                } label: {
                    Label("Ripeti: \(viewModel.repeatMode.description)", systemImage: viewModel.repeatMode.iconName)
                }
                Divider()
                TrackNavigationMenuItems(track: item)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(fg)
                    .frame(width: 40, height: 40)
                    .glassEffect(.regular.interactive(), in: .circle)
            }
            .accessibilityLabel("Altro")
        }
    }

    /// Thick bar, elapsed and remaining time, the format badge in the middle.
    private var appleScrubber: some View {
        let shown = isEditingSlider ? sliderValue : currentTime
        let maxDuration = duration > 0 ? duration : 1

        return VStack(spacing: 8) {
            PlayerBar(fraction: shown / maxDuration, isDragging: isEditingSlider, color: fg) { fraction in
                isEditingSlider = true
                sliderValue = fraction * maxDuration
            } onEnded: {
                isEditingSlider = false
                onSeek(sliderValue)
            }
            .accessibilityLabel("Posizione")
            .accessibilityValue(formatTime(shown))

            ZStack {
                HStack {
                    Text(formatTime(shown))
                    Spacer()
                    Text("-" + formatTime(max(duration - shown, 0)))
                }
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(fg.opacity(0.7))

                Button {
                    viewModel.playerManager.refreshAudioOutputInfo()
                    showAudioInfo = true
                } label: {
                    Label(qualityText, systemImage: "waveform")
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(fg.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(fg.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Info audio")
            }
        }
    }

    /// "FLAC · 24 bit · 96 kHz → 48 kHz": the original's quality, and the conversion if it is on.
    /// Without media info it falls back to the old "Lossless" / container name.
    private var qualityText: String {
        item.qualityLabel(convertedTo48k: viewModel.playerManager?.isDownsampledStream ?? false)
            ?? (item.isLossless ? "Lossless" : (item.MediaSources?.first?.Container?.uppercased() ?? "Audio"))
    }

    private var transportRow: some View {
        HStack {
            Button(action: onBackward) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 40))
                    .frame(width: 80, height: 70)
            }
            .accessibilityLabel("Precedente")
            Spacer()
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 58))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 90, height: 80)
            }
            .accessibilityLabel(isPlaying ? "Pausa" : "Riproduci")
            Spacer()
            Button(action: onForward) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 40))
                    .frame(width: 80, height: 70)
            }
            .accessibilityLabel("Successivo")
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(fg)
        .padding(.horizontal, 22)
    }

    #if os(iOS)
    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .font(.footnote)
            PlayerBar(fraction: Double(systemVolume.level), isDragging: false, color: fg) { fraction in
                systemVolume.set(Float(fraction))
            } onEnded: {}
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int(systemVolume.level * 100))%")
            Image(systemName: "speaker.wave.3.fill")
                .font(.footnote)
        }
        .foregroundStyle(fg.opacity(0.75))
        // A hidden system volume view: it moves the real volume and keeps the HUD away.
        .background(HiddenVolumeView().frame(width: 1, height: 1).opacity(0.001))
    }
    #endif

    private var bottomRow: some View {
        HStack {
            panelButton(.lyrics, systemImage: "quote.bubble", label: "Testo")
            Spacer()
            #if os(iOS)
            OutputRouteButton(color: fg)
            #else
            AirPlayView()
                .frame(width: 44, height: 44)
                .tint(fg)
            #endif
            Spacer()
            panelButton(.queue, systemImage: "list.bullet", label: "Coda")
        }
    }

    /// Lyrics and queue toggle like Apple Music's: the active one sits on a light square.
    private func panelButton(_ target: PlayerPanel, systemImage: String, label: String) -> some View {
        let active = panel == target
        return Button {
            withAnimation(.easeInOut(duration: 0.35)) { panel = active ? .artwork : target }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(active ? palette.background : fg.opacity(0.75))
                .frame(width: 44, height: 40)
                .background {
                    if active {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(fg.opacity(0.9))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Track info

    /// HIG calls for the regular variant "when components have a significant amount
    /// of text" and for components that float above media backgrounds.
    private var trackInfoPlate: some View {
        VStack(spacing: 4) {
            Text(item.Name)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            HStack(spacing: 6) {
                if item.isLossless {
                    losslessBadge
                }
                Button {
                    if let artist = viewModel.artistItem(for: item) {
                        LibraryNavigator.shared.show(.artist(artist))
                    }
                } label: {
                    Text(viewModel.artistName(for: item) ?? "")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Apre la pagina dell'artista")
            }

            if let album = item.Album {
                Text(album)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var seekSection: some View {
        VStack(spacing: 6) {
            seekProgressBar
                .frame(height: 28) // touch target

            HStack {
                Text(formatTime(currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text(formatTime(duration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Transport

    /// One glass shape for the whole transport. The secondary controls are plain
    /// buttons drawn straight on the material; only the play button is filled, with
    /// a solid tint rather than its own glass, so glass is never layered on glass.
    private var transportCapsule: some View {
        HStack(spacing: 6) {
            Button(action: { viewModel.toggleRepeatMode() }) {
                Image(systemName: viewModel.repeatMode.iconName)
                    .font(.body)
                    .foregroundStyle(viewModel.repeatMode == .off ? .white.opacity(0.8) : Color.accentColor)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onBackward) {
                Image(systemName: "backward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)

            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(playButtonTint))
                    .shadow(color: playButtonTint.opacity(0.45), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .contentTransition(.symbolEffect(.replace))

            Button(action: onForward) {
                Image(systemName: "forward.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            #if os(iOS)
            OutputRouteButton(color: .white)
            #else
            AirPlayView()
                .frame(width: 44, height: 44)
                .tint(.white)
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    // MARK: - Audio output info

    /// Collapsed summary only — the detail lives in `AudioInfoSheet`.
    private var audioInfoRow: some View {
        let pm = viewModel.playerManager!

        return Button {
            pm.refreshAudioOutputInfo()
            showAudioInfo = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text(audioInfoSummary(pm: pm))
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up")
                    .font(.caption2)
            }
            .foregroundStyle(.white.opacity(0.72))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func audioInfoSummary(pm: AudioPlayerManager) -> String {
        var parts: [String] = []
        if !pm.currentCodec.isEmpty {
            parts.append(pm.currentCodec)
        }
        if pm.currentSampleRate > 0 {
            parts.append(AudioInfoFormat.sampleRate(pm.currentSampleRate))
        }
        if !pm.currentOutputDevice.isEmpty {
            parts.append(pm.currentOutputDevice)
        }
        return parts.isEmpty ? "Info audio" : parts.joined(separator: " · ")
    }

    // MARK: - Subviews

    /// Full-bleed background: the artwork is framed to the safe content area, then
    /// `.backgroundExtensionEffect()` mirrors and blurs its edges into the surrounding
    /// safe area (Dynamic Island / home indicator) instead of a hand-rolled blur+scale hack.
    ///
    /// Guarded against degenerate geometry: mid-way through the drag-to-dismiss transition
    /// back to Home, the GeometryReader can briefly report a near-zero height. Forcing a
    /// 1pt-tall frame in that case still fed `.backgroundExtensionEffect()` a sliver too thin
    /// to mirror, which logged a "Failed to create WxH image slot" warning — so below a
    /// sane threshold we just show black for that single frame instead.
    @ViewBuilder
    private func artworkBackground(size: CGSize, safeAreaInsets: EdgeInsets) -> some View {
        let insetWidth = size.width - safeAreaInsets.leading - safeAreaInsets.trailing
        let insetHeight = size.height - safeAreaInsets.top - safeAreaInsets.bottom

        if insetWidth < 10 || insetHeight < 10 {
            Color.black
        } else {
            ZStack {
                Color.black

                CachedAsyncImage(url: artworkURL,
                    content: { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    },
                    placeholder: {
                        Color.black
                    }
                )
                .id(artworkURL)
                // Alive while playing, like Apple Music's animated backgrounds.
                .breathing(colorManager.nowPlayingBlurredBackground, moving: isPlaying)
                .frame(width: insetWidth, height: insetHeight)
                .clipped()
                .blur(radius: colorManager.nowPlayingBlurredBackground ? 45 : 0)
                // Slightly oversized while blurred so the Gaussian sampling near the
                // edges doesn't pull in the black backdrop and create a dark vignette.
                .scaleEffect(colorManager.nowPlayingBlurredBackground ? 1.15 : 1.0)
                .backgroundExtensionEffect()

                Color.black.opacity(0.35)
            }
        }
    }

    private func artworkView(size: CGFloat) -> some View {
        CachedAsyncImage(url: artworkURL,
            content: { image in
                image.resizable().aspectRatio(contentMode: .fill)
            },
            placeholder: {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.25))
                            .foregroundStyle(.white.opacity(0.4))
                    )
            }
        )
        .id(artworkURL)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var losslessBadge: some View {
        Label("FLAC", systemImage: "waveform")
            .font(.caption2)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.white.opacity(0.2))
            .clipShape(Capsule())
    }

    /// Apple Music-style thin seek bar (no round thumb).
    /// Draggable — expands slightly when touched.
    private var seekProgressBar: some View {
        GeometryReader { geo in
            let maxDuration = duration > 0 ? duration : 1
            let displayTime = isEditingSlider ? sliderValue : currentTime
            let fraction = CGFloat(displayTime / maxDuration).clamped(to: 0...1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.2))
                    .frame(height: isEditingSlider ? 6 : 4)

                Capsule()
                    .fill(.white)
                    .frame(width: max(fraction * geo.size.width, 0), height: isEditingSlider ? 6 : 4)
            }
            .frame(maxHeight: .infinity) // center vertically in the touch target
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isEditingSlider = true
                        let ratio = Double(value.location.x / geo.size.width).clamped(to: 0...1)
                        sliderValue = ratio * maxDuration
                    }
                    .onEnded { _ in
                        isEditingSlider = false
                        onSeek(sliderValue)
                    }
            )
            .animation(.easeInOut(duration: 0.15), value: isEditingSlider)
        }
    }

    @State private var volume: Double = 0.5

    private var volumeSlider: some View {
        Slider(value: $volume, in: 0...1)
            .frame(height: 20)
    }
}

// MARK: - Audio info sheet

/// Half-height sheet with the stream details. Deliberately opaque: bitrate and
/// sample rate are numbers, and numbers over glass on a light artwork are the
/// exact case the HIG warns about.
struct AudioInfoSheet: View {
    @ObservedObject var playerManager: AudioPlayerManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("Formato", playerManager.currentCodec.isEmpty ? "–" : playerManager.currentCodec)
                    row("Bitrate", AudioInfoFormat.bitrate(playerManager.currentBitrate))
                    row("Frequenza", playerManager.currentSampleRate > 0
                        ? AudioInfoFormat.sampleRate(playerManager.currentSampleRate) : "–")
                    row("Modalità",
                        playerManager.isDirectStream ? "Direct Stream" : "Transcodifica",
                        valueColor: playerManager.isDirectStream ? .green : .primary)
                    row("Uscita", playerManager.currentOutputDevice.isEmpty ? "–" : playerManager.currentOutputDevice)
                } footer: {
                    Text(playerManager.isDirectStream
                         ? "Nessuna transcodifica: il server invia il file originale."
                         : "Il server sta ricodificando il brano per questo dispositivo.")
                }
            }
            .navigationTitle("Info audio")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fine") { dismiss() }
                }
            }
        }
        .task { playerManager.refreshAudioOutputInfo() }
    }

    private func row(_ label: String, _ value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
    }
}

// MARK: - Formatting

enum AudioInfoFormat {
    static func bitrate(_ kbps: Double) -> String {
        guard kbps > 0 else { return "–" }
        if kbps >= 1000 {
            return String(format: "%.1f Mbps", kbps / 1000.0)
        }
        return "\(Int(kbps)) kbps"
    }

    static func sampleRate(_ hz: Double) -> String {
        guard hz > 0 else { return "–" }
        let kHz = hz / 1000.0
        if kHz == kHz.rounded() {
            return "\(Int(kHz)) kHz"
        }
        return String(format: "%.1f kHz", kHz)
    }
}

// MARK: - Comparable clamped helper

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Bars

/// Apple Music's thick bar: white fill on a translucent track, a little fatter while
/// dragged. Used for the song position and for the volume.
struct PlayerBar: View {
    let fraction: Double
    let isDragging: Bool
    var color: Color = .white
    let onChanged: (Double) -> Void
    let onEnded: () -> Void

    @GestureState private var pressed = false

    var body: some View {
        GeometryReader { geo in
            let value = min(max(fraction, 0), 1)
            let thick = pressed || isDragging
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.28))
                Capsule().fill(color)
                    .frame(width: max(geo.size.width * value, thick ? 11 : 7))
            }
            .frame(height: thick ? 11 : 7)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
                    .onChanged { drag in onChanged(Double(drag.location.x / max(geo.size.width, 1))) }
                    .onEnded { _ in onEnded() }
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: thick)
        }
        .frame(height: 24)
    }
}

// MARK: - Lyrics

/// The song's lyrics in big bold lines; with synced lyrics the current line lights
/// up and scrolls to the middle, and tapping a line jumps there.
private struct LyricsPanel: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let item: AudioItem
    let currentTime: TimeInterval
    var color: Color = .white
    let onSeek: (TimeInterval) -> Void

    @State private var lines: [JellyfinAPIService.LyricLine] = []
    @State private var loaded = false

    private var currentIndex: Int? {
        lines.lastIndex { ($0.start ?? .infinity) <= currentTime + 0.2 }
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().tint(color)
            } else if lines.isEmpty {
                Text("Testo non disponibile")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(color.opacity(0.6))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(lines) { line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(color.opacity(line.id == currentIndex || lines.allSatisfy({ $0.start == nil }) ? 1 : 0.35))
                                    .scaleEffect(line.id == currentIndex ? 1.0 : 0.97, anchor: .leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .onTapGesture { if let start = line.start { onSeek(start) } }
                                    .id(line.id)
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 40)
                    }
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                               .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    .onChange(of: currentIndex) {
                        guard let currentIndex else { return }
                        withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(currentIndex, anchor: .center) }
                    }
                    .animation(.easeInOut(duration: 0.3), value: currentIndex)
                }
            }
        }
        .task(id: item.Id) {
            loaded = false
            lines = await viewModel.lyrics(for: item)
            loaded = true
        }
    }
}

// MARK: - Queue

/// "A seguire": the songs after the current one; tapping one plays from there.
private struct QueuePanel: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    var color: Color = .white

    var body: some View {
        // Observed, so additions and removals show up at once.
        QueueList(manager: viewModel.playerManager!, color: color)
    }
}

private struct QueueList: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject var manager: AudioPlayerManager
    let color: Color

    var body: some View {
        let upNext = manager.upNext
        let queued = upNext.filter { !manager.autoplayIds.contains($0.id) }
        let autoplay = upNext.filter { manager.autoplayIds.contains($0.id) }

        VStack(alignment: .leading, spacing: 8) {
            // Apple Music's queue header: title, then shuffle · repeat · autoplay.
            HStack {
                Text("A seguire")
                    .font(.headline)
                    .foregroundStyle(color)
                Spacer()
                toggle("shuffle", label: "Casuale", isOn: manager.isShuffled) {
                    withAnimation(.snappy) { manager.toggleShuffle() }
                }
                toggle(viewModel.repeatMode.iconName, label: "Ripeti", isOn: viewModel.repeatMode != .off) {
                    viewModel.toggleRepeatMode()
                }
                toggle("infinity", label: "Riproduzione automatica", isOn: manager.autoplayEnabled) {
                    withAnimation(.snappy) { manager.autoplayEnabled.toggle() }
                }
            }
            .padding(.horizontal, 32)

            if upNext.isEmpty {
                Text(manager.autoplayEnabled && viewModel.repeatMode == .off ? "Cerco brani simili…" : "Nessun altro brano in coda.")
                    .font(.subheadline)
                    .foregroundStyle(color.opacity(0.6))
                    .padding(.horizontal, 32)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(queued) { track in row(track) }
                        if !autoplay.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Riproduzione automatica")
                                    .font(.headline)
                                    .foregroundStyle(color)
                                Text("Brani simili, da Jellyfin")
                                    .font(.caption)
                                    .foregroundStyle(color.opacity(0.6))
                            }
                            .padding(.top, queued.isEmpty ? 0 : 18)
                            .padding(.bottom, 4)
                            ForEach(autoplay) { track in row(track) }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
                }
                // Rows fade out above the title instead of being cut off.
                .mask {
                    LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.85),
                                           .init(color: .clear, location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .padding(.top, 20)
    }

    /// A square toggle like Apple Music's: filled when on.
    private func toggle(_ systemImage: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                // On: the page's text color as fill, the icon in the opposite one.
                .foregroundStyle(isOn ? (color == .black ? Color.white : Color.black) : color.opacity(0.8))
                .frame(width: 38, height: 30)
                .background(isOn ? color.opacity(0.9) : color.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func row(_ track: AudioItem) -> some View {
        Button {
            manager.play(item: track, in: manager.queue)
        } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(url: viewModel.artworkURL(for: track.AlbumId ?? track.id, size: 100), targetSize: 44,
                    content: { $0.resizable().aspectRatio(contentMode: .fill) },
                    placeholder: { RoundedRectangle(cornerRadius: 6).fill(color.opacity(0.15)) }
                )
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.Name)
                        .font(.body)
                        .foregroundStyle(color)
                        .lineLimit(1)
                    Text(viewModel.artistName(for: track) ?? "")
                        .font(.subheadline)
                        .foregroundStyle(color.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                viewModel.playNext([track])
            } label: {
                Label("Riproduci dopo", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            Button(role: .destructive) {
                withAnimation { manager.removeFromQueue(track) }
            } label: {
                Label("Rimuovi dalla coda", systemImage: "minus.circle")
            }
            Divider()
            TrackNavigationMenuItems(track: track)
        }
    }
}

#if os(iOS)
// MARK: - System volume

/// The device volume: read from the audio session, set through a hidden MPVolumeView
/// (the only way an app may change it).
@MainActor
final class SystemVolume: ObservableObject {
    static let shared = SystemVolume()

    @Published private(set) var level: Float = AVAudioSession.sharedInstance().outputVolume
    fileprivate weak var slider: UISlider?
    private var observation: NSKeyValueObservation?

    private init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, _ in
            let value = session.outputVolume
            Task { @MainActor in self?.level = value }
        }
    }

    func set(_ value: Float) {
        let clamped = min(max(value, 0), 1)
        level = clamped
        slider?.value = clamped
    }
}

private struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        DispatchQueue.main.async {
            SystemVolume.shared.slider = view.subviews.compactMap { $0 as? UISlider }.first
        }
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
#endif
