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
    #if os(iOS)
    @State private var deviceKey: String?
    @State private var chosenSymbol: String?
    #endif

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
                #if os(iOS)
                if let deviceKey {
                    iconMenu(for: deviceKey)
                }
                #endif
                AirPlayView()
                    .frame(width: 44, height: 44)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Uscita audio")
        } footer: {
            Text("Il dispositivo su cui suona l'audio. Tocca il pulsante AirPlay per cambiarlo. L'icona resta anche se rinomini il dispositivo; se non è quella giusta, sceglila dal menu.")
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
        symbol = Self.symbol(for: output)
        let external = output.portType != .builtInSpeaker && output.portType != .builtInReceiver
        deviceKey = external ? OutputDeviceMemory.key(for: output) : nil
        chosenSymbol = deviceKey.flatMap(OutputDeviceMemory.chosen)
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

    private func iconMenu(for key: String) -> some View {
        Menu {
            Picker("Icona", selection: Binding(
                get: { chosenSymbol ?? "" },
                set: { newValue in
                    OutputDeviceMemory.choose(newValue.isEmpty ? nil : newValue, for: key)
                    withAnimation { refresh() }
                }
            )) {
                Text("Automatica").tag("")
                ForEach(OutputDeviceMemory.choices, id: \.symbol) { choice in
                    Label(choice.label, systemImage: choice.symbol).tag(choice.symbol)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("Icona del dispositivo")
    }

    /// The drawing for an output: the one chosen in Settings, else the product's from its
    /// name, else the one learned when the name still said it (renamed buds keep theirs),
    /// else one for its kind of port.
    static func symbol(for output: AVAudioSessionPortDescription) -> String {
        let key = OutputDeviceMemory.key(for: output)
        if let chosen = OutputDeviceMemory.chosen(for: key) { return chosen }
        if let product = productSymbol(for: output.portName) {
            OutputDeviceMemory.learn(product, for: key)
            return product
        }
        return OutputDeviceMemory.learned(for: key) ?? portSymbol(for: output.portType)
    }

    /// The product drawing that matches the device's name, if any.
    private static func productSymbol(for name: String) -> String? {
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
            ("buds", "earbuds"),
            ("earbuds", "earbuds"),
            ("homepod mini", "homepod.mini.fill"),
            ("homepod", "homepod.fill"),
            ("apple tv", "appletv.fill"),
        ]
        guard let match = byName.first(where: { n.contains($0.0) })?.1, UIImage(systemName: match) != nil else {
            return nil
        }
        return match
    }

    private static func portSymbol(for type: AVAudioSession.Port) -> String {
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

#if os(iOS)
/// Remembers the drawing of each external output by its hardware address, which stays
/// the same when the device is renamed.
enum OutputDeviceMemory {
    private static let chosenKey = "outputDeviceChosenSymbols"
    private static let learnedKey = "outputDeviceLearnedSymbols"

    static let choices: [(label: String, symbol: String)] = [
        ("Cuffiette", "earbuds"),
        ("AirPods", "airpods.gen3"),
        ("AirPods Pro", "airpods.pro"),
        ("Cuffie", "headphones"),
        ("Altoparlante", "hifispeaker.fill"),
        ("Auto", "car.fill"),
    ]

    /// A Bluetooth uid is the address plus the profile ("…-tacl" for music, "…-tsco" for
    /// calls): only the address, so both profiles share the icon.
    static func key(for output: AVAudioSessionPortDescription) -> String {
        let uid = output.uid
        if uid.count >= 17, uid.prefix(17).filter({ $0 == ":" }).count == 5 {
            return String(uid.prefix(17)).uppercased()
        }
        return uid
    }

    static func chosen(for key: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: chosenKey) as? [String: String])?[key]
    }

    static func choose(_ symbol: String?, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: chosenKey) as? [String: String] ?? [:]
        all[key] = symbol
        UserDefaults.standard.set(all, forKey: chosenKey)
    }

    static func learned(for key: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: learnedKey) as? [String: String])?[key]
    }

    static func learn(_ symbol: String, for key: String) {
        var all = UserDefaults.standard.dictionary(forKey: learnedKey) as? [String: String] ?? [:]
        guard all[key] != symbol else { return }
        all[key] = symbol
        UserDefaults.standard.set(all, forKey: learnedKey)
    }
}
#endif
