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
    
    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            CachedAsyncImage(url: artworkURL,
                content: { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                },
                placeholder: {
                    Rectangle().fill(.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
                }
            )
            .id(artworkURL)
            .frame(width: 32, height: 32)
            .cornerRadius(6)
            
            VStack(alignment: .leading, spacing: 0) {
                Text(item.Name)
                    .font(.caption)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if item.isLossless {
                        Label("FLAC", systemImage: "waveform")
                            .font(.caption2)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.15))
                            .clipShape(Capsule())
                    }
                    if let artist = item.mainArtistName {
                        Text(artist)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 100, maxWidth: 150, alignment: .leading)
            
            Text(formatTime(currentTime))
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(minWidth: 40)
            
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
            .frame(height: 20)
            
            Text(formatTime(duration))
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(minWidth: 40)
            
            HStack(spacing: 10) {
                Button(action: onBackward) {
                    Image(systemName: "backward.fill").font(.caption)
                }
                .buttonStyle(.plain)
                
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.caption)
                }
                .buttonStyle(.plain)
                
                Button(action: onForward) {
                    Image(systemName: "forward.fill").font(.caption)
                }
                .buttonStyle(.plain)
                
                Button(action: { viewModel.toggleRepeatMode() }) {
                    Image(systemName: viewModel.repeatMode.iconName).font(.caption)
                }
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
                    .frame(width: 24, height: 24)
            }
            .frame(minWidth: 130)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 16)
        .glassEffect()
        .cornerRadius(10)
        .onChange(of: currentTime) {
            if !isEditingSlider {
                sliderValue = currentTime
            }
        }
    }
}
