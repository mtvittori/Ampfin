import SwiftUI
import AVKit

#if os(macOS)
struct AirPlayView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        // Just the icon, without the gray button behind it.
        picker.isRoutePickerButtonBordered = false
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#else
import UIKit

struct AirPlayView: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        AVRoutePickerView()
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

#if os(iOS)
/// The AirPlay button of the player, showing where the sound goes: on the iPhone
/// speaker the usual AirPlay icon, otherwise the device's drawing and name
/// ("Galaxy Buds", "AirPods Pro"…), like Apple Music. Tapping opens the system picker.
struct OutputRouteButton: View {
    var color: Color = .primary

    @State private var name = ""
    @State private var symbol = "airplayaudio"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
            if !name.isEmpty {
                Text(name)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .foregroundStyle(color)
        .frame(minWidth: 44, minHeight: 44)
        // The real picker on top, invisible: it gets the tap and opens the system menu.
        .overlay(InvisibleRoutePicker())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.isEmpty ? "AirPlay" : "Uscita audio: \(name)")
        .accessibilityAddTraits(.isButton)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            DispatchQueue.main.async { withAnimation(.snappy) { refresh() } }
        }
    }

    private func refresh() {
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first,
              output.portType != .builtInSpeaker, output.portType != .builtInReceiver else {
            name = ""
            symbol = "airplayaudio"
            return
        }
        name = output.portName
        symbol = AudioOutputSection.symbol(for: output)
    }
}

private struct InvisibleRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .clear
        picker.activeTintColor = .clear
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif
