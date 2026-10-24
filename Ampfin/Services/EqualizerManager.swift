import Foundation
import AVFoundation

/// Manages a 10-band parametric equalizer using AVAudioEngine + AVAudioUnitEQ.
/// Owns the audio engine and player node; AudioPlayerManager uses this for playback.
final class EqualizerManager: ObservableObject {
    static let shared = EqualizerManager()

    // MARK: - Public State

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "eq_enabled")
            applyGains()
        }
    }

    @Published var selectedPreset: EQPreset {
        didSet {
            UserDefaults.standard.set(selectedPreset.rawValue, forKey: "eq_preset")
            applyPreset(selectedPreset)
        }
    }

    /// Per-band gain values in dB (-12…+12). Index matches `bandFrequencies`.
    @Published var bandGains: [Float] {
        didSet {
            UserDefaults.standard.set(bandGains, forKey: "eq_bandGains")
            applyGains()
        }
    }

    /// Standard 10-band center frequencies (Hz).
    static let bandFrequencies: [Float] = [
        32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    /// Human-readable labels for each band.
    static let bandLabels: [String] = [
        "32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"
    ]

    // MARK: - Audio Engine Components (used by AudioPlayerManager)

    /// These are replaced when the graph is rebuilt (see `rebuildEngine`): read them from here
    /// every time, never keep a reference.
    private(set) var audioEngine = AVAudioEngine()
    private(set) var playerNode = AVAudioPlayerNode()
    private var eq: AVAudioUnitEQ
    private var configurationObserver: NSObjectProtocol?

    /// The format the chain is wired for. Rewiring is skipped when a song has the same
    /// one: AVAudioEngine can raise an exception while connecting, and that aborted the app.
    private var connectedFormat: AVAudioFormat?

    /// Called when the system stops the engine because the output changed
    /// (CarPlay, Bluetooth, headphones), so playback can start it again.
    var onConfigurationChange: (() -> Void)?

    // MARK: - Init

    /// Reads the saved settings again, after a backup has been restored.
    func reloadFromDefaults() {
        isEnabled = UserDefaults.standard.bool(forKey: "eq_enabled")
        selectedPreset = EQPreset(rawValue: UserDefaults.standard.string(forKey: "eq_preset") ?? "") ?? .flat
        bandGains = UserDefaults.standard.array(forKey: "eq_bandGains") as? [Float] ?? EQPreset.flat.gains
    }

    private init() {
        let savedEnabled = UserDefaults.standard.bool(forKey: "eq_enabled")
        let savedPreset = EQPreset(rawValue: UserDefaults.standard.string(forKey: "eq_preset") ?? "") ?? .flat
        let savedGains = UserDefaults.standard.array(forKey: "eq_bandGains") as? [Float]

        self.isEnabled = savedEnabled
        self.selectedPreset = savedPreset
        self.bandGains = savedGains ?? EQPreset.flat.gains
        self.eq = AVAudioUnitEQ(numberOfBands: 10)

        setupEngine()
        observeConfigurationChanges()
    }

    /// Watches the current engine; called again for a rebuilt one.
    private func observeConfigurationChanges() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main) { [weak self] _ in
            guard let self else { return }
            PlaybackLog.log("EqualizerManager: configuration change, engine running=\(self.audioEngine.isRunning) \(PlaybackLog.routeDescription())")
            // The engine is stopped and its formats may be stale: rewire on the next song.
            self.connectedFormat = nil
            self.onConfigurationChange?()
        }
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        // Configure EQ bands
        for (i, band) in eq.bands.enumerated() {
            band.filterType = .parametric
            band.frequency = Self.bandFrequencies[i]
            band.bandwidth = 1.0 // 1 octave
            band.gain = isEnabled && bandGains.indices.contains(i) ? bandGains[i] : 0
            band.bypass = false
        }
        eq.globalGain = 0

        // Attach nodes
        audioEngine.attach(playerNode)
        audioEngine.attach(eq)

        // Connect: playerNode -> EQ -> mainMixer -> output
        // Use a default stereo format; reconnect with correct format when scheduling audio
        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        audioEngine.connect(playerNode, to: eq, format: defaultFormat)
        audioEngine.connect(eq, to: audioEngine.mainMixerNode, format: defaultFormat)
        connectedFormat = defaultFormat
    }

    /// Reconnect the signal chain with the correct audio format from the file being played.
    /// Returns false when the engine refused the format even after a reset.
    @discardableResult
    func reconnect(withFormat format: AVAudioFormat) -> Bool {
        if let connectedFormat, connectedFormat == format { return true }

        let wasRunning = audioEngine.isRunning
        PlaybackLog.log("EqualizerManager: format \(PlaybackLog.describe(connectedFormat)) -> \(PlaybackLog.describe(format)), engine running=\(wasRunning) \(PlaybackLog.routeDescription())")
        if wasRunning { audioEngine.stop() }

        var exception = AmpfinCatchException { self.wire(format) }
        if let first = exception {
            PlaybackLog.log("EqualizerManager: rewiring failed (attempt 1) – \(first.name.rawValue): \(first.reason ?? "")")
            // Start over from a clean graph and try once more.
            playerNode.stop()
            audioEngine.reset()
            exception = AmpfinCatchException { self.wire(format) }
            if let second = exception {
                PlaybackLog.log("EqualizerManager: rewiring failed (attempt 2) – \(second.name.rawValue): \(second.reason ?? "")")
                // Last resort: the engine itself may be in a state a reset does not clear.
                exception = rebuildEngine(wiring: format)
            } else {
                PlaybackLog.log("EqualizerManager: rewiring succeeded on attempt 2")
            }
        }
        connectedFormat = exception == nil ? format : nil

        if wasRunning {
            startEngine()
        }
        return exception == nil
    }

    /// Replaces the engine, the player node and the EQ unit with new ones, applies the
    /// current settings and wires the chain for `format`. Returns the exception if even
    /// that fails. AudioPlayerManager reads the nodes from here each time, and opens the
    /// next file (which schedules it on the new node) after this, so nothing queued on the
    /// old node is needed.
    private func rebuildEngine(wiring format: AVAudioFormat) -> NSException? {
        PlaybackLog.log("EqualizerManager: rebuilding the audio engine")
        let volume = audioEngine.mainMixerNode.outputVolume
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil

        let oldEngine = audioEngine
        let oldPlayer = playerNode
        _ = AmpfinCatchException {
            oldPlayer.stop()
            oldEngine.stop()
        }

        audioEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()
        eq = AVAudioUnitEQ(numberOfBands: 10)
        observeConfigurationChanges()

        let exception = AmpfinCatchException {
            self.setupEngine()
            self.audioEngine.mainMixerNode.outputVolume = volume
            self.wire(format)
        }
        if let exception {
            PlaybackLog.log("EqualizerManager: rebuild FAILED – \(exception.name.rawValue): \(exception.reason ?? "")")
        } else {
            PlaybackLog.log("EqualizerManager: rebuild succeeded for \(PlaybackLog.describe(format))")
        }
        return exception
    }

    private func wire(_ format: AVAudioFormat) {
        audioEngine.disconnectNodeInput(eq)
        audioEngine.disconnectNodeInput(audioEngine.mainMixerNode)

        audioEngine.connect(playerNode, to: eq, format: format)
        audioEngine.connect(eq, to: audioEngine.mainMixerNode, format: format)
    }

    /// Returns whether the engine is running afterwards. After a call or an output change
    /// the first start can fail: the graph is prepared again and started once more.
    @discardableResult
    func startEngine() -> Bool {
        guard !audioEngine.isRunning else { return true }
        for attempt in 1...2 {
            if attempt == 2 { _ = AmpfinCatchException { self.audioEngine.prepare() } }
            var startError: Error?
            let exception = AmpfinCatchException {
                do { try self.audioEngine.start() } catch { startError = error }
            }
            if audioEngine.isRunning { return true }
            PlaybackLog.log("EqualizerManager: Failed to start engine (attempt \(attempt)) – \(startError.map { "\($0)" } ?? exception?.reason ?? "unknown") \(PlaybackLog.routeDescription())")
        }
        return false
    }

    func stopEngine() {
        playerNode.stop()
        audioEngine.stop()
    }

    /// Paused, not stopped: the graph and the queued song stay, and start() goes on from
    /// here. On iOS the lock screen reads play/pause from whether the app is making sound:
    /// an engine left running while paused kept the pause button there and play was lost.
    func pauseEngine() {
        guard audioEngine.isRunning else { return }
        audioEngine.pause()
    }

    // MARK: - Apply

    private func applyGains() {
        for (i, band) in eq.bands.enumerated() where bandGains.indices.contains(i) {
            band.gain = isEnabled ? bandGains[i] : 0
        }
    }

    private func applyPreset(_ preset: EQPreset) {
        bandGains = preset.gains
    }

    /// Resets the EQ to flat.
    func resetToFlat() {
        selectedPreset = .flat
    }

    /// Updates a single band gain.
    func setGain(_ gain: Float, forBand index: Int) {
        guard bandGains.indices.contains(index) else { return }
        bandGains[index] = gain
        selectedPreset = .custom
    }
}

// MARK: - EQ Presets

enum EQPreset: String, CaseIterable, Identifiable {
    case flat = "flat"
    case bassBoost = "bassBoost"
    case trebleBoost = "trebleBoost"
    case vocal = "vocal"
    case rock = "rock"
    case pop = "pop"
    case jazz = "jazz"
    case classical = "classical"
    case electronic = "electronic"
    case hiphop = "hiphop"
    case acoustic = "acoustic"
    case custom = "custom"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: return "Piatto"
        case .bassBoost: return "Bassi potenziati"
        case .trebleBoost: return "Alti potenziati"
        case .vocal: return "Voce"
        case .rock: return "Rock"
        case .pop: return "Pop"
        case .jazz: return "Jazz"
        case .classical: return "Classica"
        case .electronic: return "Elettronica"
        case .hiphop: return "Hip-Hop"
        case .acoustic: return "Acustica"
        case .custom: return "Personalizzato"
        }
    }

    /// Gain values for each of the 10 bands: 32, 64, 125, 250, 500, 1K, 2K, 4K, 8K, 16K
    var gains: [Float] {
        switch self {
        case .flat:
            return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .bassBoost:
            return [8, 6, 4, 2, 0, 0, 0, 0, 0, 0]
        case .trebleBoost:
            return [0, 0, 0, 0, 0, 0, 2, 4, 6, 8]
        case .vocal:
            return [-2, -1, 0, 2, 5, 5, 3, 1, 0, -1]
        case .rock:
            return [5, 4, 2, 0, -1, 0, 2, 4, 5, 6]
        case .pop:
            return [-1, 1, 3, 4, 3, 0, -1, 1, 2, 3]
        case .jazz:
            return [3, 2, 0, 1, -1, -1, 0, 1, 3, 4]
        case .classical:
            return [4, 3, 1, 0, -1, -1, 0, 2, 3, 4]
        case .electronic:
            return [6, 5, 3, 0, -2, 0, 1, 3, 5, 6]
        case .hiphop:
            return [7, 6, 4, 1, 0, -1, 1, 0, 2, 3]
        case .acoustic:
            return [3, 2, 0, 1, 2, 1, 0, 1, 2, 2]
        case .custom:
            return UserDefaults.standard.array(forKey: "eq_bandGains") as? [Float] ?? [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        }
    }
}
