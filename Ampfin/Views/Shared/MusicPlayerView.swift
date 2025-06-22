import SwiftUI

struct MusicPlayerView: View {
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
        // Il VStack è il contenitore principale del nostro contenuto
        VStack(spacing: 0) {
            HStack {
                Text(formatTime(currentTime))
                    .font(.caption2).foregroundColor(.secondary).frame(minWidth: 40)
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
                Text(formatTime(duration))
                    .font(.caption2).foregroundColor(.secondary).frame(minWidth: 40)
            }

            HStack(spacing: 15) {
                           // Gruppo 1: Artwork e Titolo
                           // Li mettiamo insieme in un HStack
                           HStack(spacing: 12) {
                               CachedAsyncImage(url: artworkURL) { image in image.resizable().aspectRatio(contentMode: .fill) }
                               placeholder: { Rectangle().fill(.gray.opacity(0.2)).overlay(Image(systemName: "music.note")) }
                               .frame(width: 55, height: 55).cornerRadius(6)
                               
                               VStack(alignment: .leading, spacing: 2) {
                                   Text(item.Name).font(.headline).lineLimit(1)
                                   if let artist = item.mainArtistName {
                                       Text(artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                                   }
                               }
                           }
                           
                           // Gruppo 2: Spacer per spingere i controlli a destra
                           // Questo è il componente chiave che crea lo spazio
                           Spacer()
                           
                           // Gruppo 3: Controlli di riproduzione
                           HStack(spacing: 20) {
                               Button(action: onBackward) { Image(systemName: "backward.fill").font(.title2) }.buttonStyle(.plain)
                               Button(action: onPlayPause) { Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.largeTitle) }.buttonStyle(.plain)
                               Button(action: onForward) { Image(systemName: "forward.fill").font(.title2) }.buttonStyle(.plain)
                               AirPlayView().frame(width: 30, height: 30)
                           }
                       }
                       .padding(.top, 8)
                       // --- FINE MODIFICA QUI ---
                   }
        // --- INIZIO MODIFICHE DI STILE (APPLICATE AL VSTACK) ---
        
        // 1. Aggiungiamo il padding *interno* per dare aria al contenuto
        .padding(.vertical, 16)
        .padding(.horizontal, 32)

        // 2. Applichiamo lo sfondo con l'effetto vetro
        .glassEffect()
        
        // 3. Arrotondiamo gli angoli
        
        // 4. Aggiungiamo l'ombra
        // .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: -5)
        
        // --- FINE MODIFICHE DI STILE ---
        
        .onChange(of: currentTime) {
            if !isEditingSlider {
                sliderValue = currentTime
            }
        }
    }
}
