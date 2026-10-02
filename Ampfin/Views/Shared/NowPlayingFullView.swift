import SwiftUI

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
                // Background: the artist photo panning (Zune), or the blurred artwork
                if colorManager.zuneStyleEnabled {
                    ZuneBackdrop(urls: viewModel.artistImageURLs(for: item), dim: 0.4)
                } else {
                    artworkBackground(size: geo.size, safeAreaInsets: geo.safeAreaInsets)
                }

                VStack(spacing: 0) {
                    // Drag indicator — positioned well below Dynamic Island / status bar
                    Capsule()
                        .fill(.white.opacity(0.4))
                        .frame(width: 36, height: 5)
                        .padding(.top, max(geo.safeAreaInsets.top, 59) + 16)

                    Spacer()

                    if colorManager.zuneStyleEnabled {
                        zuneHeader
                    } else {
                        // Large artwork — fill more width
                        let artworkSize = min(geo.size.width - 48, 380)
                        artworkView(size: artworkSize)
                            .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
                            .scaleEffect(isPlaying ? 1.0 : 0.9)
                            .animation(.spring(response: 0.5, dampingFraction: 0.7), value: isPlaying)

                        Spacer().frame(height: 36)

                        trackInfoPlate
                            .padding(.horizontal, 32)
                    }

                    Spacer().frame(height: 28)

                    seekSection
                        .padding(.horizontal, 32)

                    Spacer().frame(height: 26)

                    transportCapsule
                        .padding(.horizontal, 24)

                    if isVolumeSliderEnabled {
                        Spacer().frame(height: 28)

                        HStack(spacing: 10) {
                            Image(systemName: "speaker.fill")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.5))
                            volumeSlider
                                .tint(.white.opacity(0.6))
                            Image(systemName: "speaker.wave.3.fill")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.horizontal, 32)
                    }

                    Spacer().frame(height: 16)

                    audioInfoRow
                        .padding(.horizontal, 24)

                    Spacer(minLength: 0)
                        .frame(maxHeight: max(geo.safeAreaInsets.bottom, 34) + 16)
                }
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
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
                                isExpanded = false
                            }
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
        // Audio details live in a sheet, not in an expanding glass plate: the numbers
        // sit on an opaque background where they stay legible, and the player's glass
        // row never changes height.
        .sheet(isPresented: $showAudioInfo) {
            AudioInfoSheet(playerManager: viewModel.playerManager!)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    private func loadAverageColor(url: URL?) async {
        guard let url else { avgColor = .clear; return }
        let key = ImageCacheService.shared.key(for: url)
        if let cached = ImageCacheService.shared.getImage(forKey: key),
           let color = cached.averageColor() {
            avgColor = color
        }
    }

    // MARK: - Zune header

    /// Zune HD layout: the artist name huge and drifting across the photo, then a
    /// small square cover beside the song and album in lowercase.
    private var zuneHeader: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZuneDriftingText(text: viewModel.artistName(for: item) ?? "", size: 112)

            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(url: artworkURL,
                    content: { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    },
                    placeholder: {
                        Rectangle().fill(.white.opacity(0.12))
                    }
                )
                .id(artworkURL)
                .frame(width: 92, height: 92)
                .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    if item.isLossless {
                        losslessBadge
                            .padding(.bottom, 4)
                    }
                    Text(item.Name.lowercased())
                        .font(.zune(28, .semilight, relativeTo: .title2))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                    if let album = item.Album {
                        Text(album.lowercased())
                            .font(.zune(17, .regular, relativeTo: .subheadline))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
        }
        .accessibilityElement(children: .combine)
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
                Text(item.mainArtistName ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
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

            AirPlayView()
                .frame(width: 44, height: 44)
                .tint(.white)
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

// MARK: - Drifting name

/// Artist name wider than the screen, sliding slowly back and forth so the whole
/// name passes by, like the Zune HD now playing screen.
private struct ZuneDriftingText: View {
    let text: String
    let size: CGFloat

    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let travel = max(textWidth - geo.size.width + 56, 0)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Text(text.lowercased())
                    .font(.zune(size, .light, relativeTo: .largeTitle))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
                    .offset(x: 28 - travel * (0.5 - 0.5 * cos(t / 9)))
            }
        }
        .frame(height: size * 1.15)
        .accessibilityLabel(text)
    }
}
