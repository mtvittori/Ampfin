import SwiftUI

struct MusicPlayerView: View {
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
    
    @State private var sliderValue: Double = 0
    @State private var isEditingSlider: Bool = false

    // Scale: 1.5x
    private let uiScale: CGFloat = 1.5
    private var artworkSize: CGFloat { 32 * uiScale }           // was 32
    private var minTitleWidth: CGFloat { 100 * uiScale }       // was 100
    private var maxTitleWidth: CGFloat { 150 * uiScale }       // was 150
    private var timeWidth: CGFloat { 40 * uiScale }            // was 40
    private var sliderHeight: CGFloat { 20 * uiScale }         // was 20
    private var controlMinWidth: CGFloat { 130 * uiScale }     // was 130
    private var iconFontSize: CGFloat { 12 * uiScale }         // approximate caption size scaled
    private var iconSmallFontSize: CGFloat { 11 * uiScale }    // approximate caption2 size scaled
    private var airplaySize: CGFloat { 24 * uiScale }          // was 24
    private var horizontalPadding: CGFloat { 16 * uiScale }    // was 16
    private var verticalPadding: CGFloat { 4 * uiScale }       // was 4
    private var cornerRadiusVal: CGFloat { 10 * uiScale }      // was 10
    private var overlayLineWidth: CGFloat { 0.6 * uiScale }    // was 0.6
    private var shadowRadius: CGFloat { 6 * uiScale }          // was 6

    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var body: some View {
        HStack(spacing: 8 * uiScale) {
            CachedAsyncImage(url: artworkURL,
                content: { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                },
                placeholder: {
                    Rectangle().fill(.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
                }
            )
            .id(artworkURL)
            .frame(width: artworkSize, height: artworkSize)
            .cornerRadius(6 * uiScale)
            
            VStack(alignment: .leading, spacing: 2 * uiScale) {
                Text(item.Name)
                    .font(.system(size: iconFontSize)) // scaled caption
                    .lineLimit(1)
                HStack(spacing: 4 * uiScale) {
                    if item.isLossless {
                        Label("FLAC", systemImage: "waveform")
                            .font(.system(size: iconSmallFontSize))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 4 * uiScale)
                            .padding(.vertical, 1 * uiScale)
                            .background(Color.blue.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if let artist = item.mainArtistName {
                        Text(artist)
                            .font(.system(size: iconSmallFontSize))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minWidth: minTitleWidth, maxWidth: maxTitleWidth, alignment: .leading)
            
            Text(formatTime(currentTime))
                .font(.system(size: iconSmallFontSize))
                .foregroundColor(.secondary)
                .frame(minWidth: timeWidth)
            
            Slider(
                value: Binding(
                    get: { isEditingSlider ? sliderValue : currentTime },
                    set: { sliderValue = $0 }
                ),
                in: 0...(duration > 0 ? duration : 1),
                onEditingChanged: { editing in
                    isEditingSlider = editing
                    if !editing { onSeek(sliderValue) }
                }
            )
            .frame(height: sliderHeight)
            
            Text(formatTime(duration))
                .font(.system(size: iconSmallFontSize))
                .foregroundColor(.secondary)
                .frame(minWidth: timeWidth)
            
            HStack(spacing: 10 * uiScale) {
                Button(action: onBackward) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: iconFontSize))
                }
                .buttonStyle(.plain)
                
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: iconFontSize))
                }
                .buttonStyle(.plain)
                
                Button(action: onForward) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: iconFontSize))
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.toggleRepeatMode() }) {
                    Image(systemName: viewModel.repeatMode.iconName)
                        .font(.system(size: iconFontSize))
                }
                .buttonStyle(.plain)
                .foregroundColor(viewModel.repeatMode == .off ? .primary : .accentColor)
                .accessibilityLabel("Repeat mode")
                .help({
                    switch viewModel.repeatMode {
                    case .off: return "Repeat off"
                    case .all: return "Repeat all"
                    case .one: return "Repeat one"
                    }
                }())
                
                AirPlayView()
                    .frame(width: airplaySize, height: airplaySize)
            }
            .frame(minWidth: controlMinWidth)
        }
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadiusVal, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadiusVal, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: overlayLineWidth)
        )
        .shadow(radius: shadowRadius)
        .onChange(of: currentTime) {
            if !isEditingSlider {
                sliderValue = currentTime
            }
        }
    }
}
