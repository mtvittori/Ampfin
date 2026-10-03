// AudioOutputSection.swift
// Settings → "Uscita audio": the device the sound is going to, with its picture.
// iOS doesn't give apps the product photos it shows in Control Center, but SF Symbols
// has a drawing for most Apple and Beats products, chosen here from the device name.

import SwiftUI
#if os(iOS)
import AVFoundation
#endif

struct AudioOutputSection: View {
    @State private var name = ""
    @State private var kind = ""
    @State private var symbol = "speaker.wave.2.fill"

    var body: some View {
        Section {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 40, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)
                    .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                    Text(kind)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AirPlayView()
                    .frame(width: 44, height: 44)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Uscita audio")
        } footer: {
            Text("Il dispositivo su cui suona l'audio. Tocca il pulsante AirPlay per cambiarlo.")
        }
        .onAppear(perform: refresh)
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { _ in
            DispatchQueue.main.async { withAnimation { refresh() } }
        }
        #endif
    }

    private func refresh() {
        #if os(iOS)
        guard let output = AVAudioSession.sharedInstance().currentRoute.outputs.first else {
            name = "Nessuna uscita"
            kind = ""
            symbol = "speaker.slash.fill"
            return
        }
        name = output.portType == .builtInSpeaker ? "iPhone" : output.portName
        kind = Self.kindLabel(output.portType)
        symbol = Self.symbol(for: output.portName, type: output.portType)
        #else
        name = "Mac"
        kind = "Uscita di sistema"
        symbol = "macbook"
        #endif
    }

    #if os(iOS)
    private static func kindLabel(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInSpeaker: return "Altoparlante"
        case .builtInReceiver: return "Ricevitore"
        case .headphones: return "Cuffie con filo"
        case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "Bluetooth"
        case .airPlay: return "AirPlay"
        case .carAudio: return "CarPlay"
        case .HDMI: return "HDMI"
        case .usbAudio: return "USB"
        default: return type.rawValue
        }
    }

    /// The product drawing that matches the device's name, then one for its kind of port.
    static func symbol(for name: String, type: AVAudioSession.Port) -> String {
        let n = name.lowercased()
        let byName: [(String, String)] = [
            ("airpods max", "airpods.max"),
            ("airpods pro", "airpods.pro"),
            ("airpods 4", "airpods.gen4"),
            ("airpods", "airpods.gen3"),
            ("powerbeats pro 2", "beats.powerbeats.pro.2"),
            ("powerbeats pro", "beats.powerbeats.pro"),
            ("powerbeats", "beats.powerbeats"),
            ("fit pro", "beats.fit.pro"),
            ("studio buds +", "beats.studiobuds.plus"),
            ("studio buds plus", "beats.studiobuds.plus"),
            ("studio buds", "beats.studiobuds"),
            ("solo buds", "beats.solobuds"),
            ("pill", "beats.pill"),
            ("flex", "beats.earphones"),
            ("beatsx", "beats.earphones"),
            ("urbeats", "beats.earphones"),
            ("beats", "beats.headphones"),
            ("homepod mini", "homepod.mini.fill"),
            ("homepod", "homepod.fill"),
            ("apple tv", "appletv.fill"),
        ]
        if let match = byName.first(where: { n.contains($0.0) })?.1, UIImage(systemName: match) != nil {
            return match
        }
        switch type {
        case .builtInSpeaker, .builtInReceiver: return "iphone"
        case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: return "headphones"
        case .airPlay: return "airplayaudio"
        case .carAudio: return "car.fill"
        case .HDMI: return "tv"
        default: return "hifispeaker.fill"
        }
    }
    #endif
}
