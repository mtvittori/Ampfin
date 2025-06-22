import SwiftUI
import AVKit

struct AirPlayView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let routePickerView = AVRoutePickerView()
        // Su macOS non sono necessarie altre configurazioni
        return routePickerView
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        // Nessun aggiornamento necessario
    }
}
