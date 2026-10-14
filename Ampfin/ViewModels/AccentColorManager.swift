import SwiftUI

/// Which of the playing cover's colors the accent takes.
enum ArtworkAccentChoice: String, CaseIterable, Identifiable {
    case primary, secondary
    var id: String { rawValue }
    var label: String {
        switch self {
        case .primary: "Primario"
        case .secondary: "Secondario"
        }
    }
}

/// Manages the user-selected accent color, persisted in UserDefaults.
class AccentColorManager: ObservableObject {
    static let shared = AccentColorManager()

    private static let redKey = "accentColor_red"
    private static let greenKey = "accentColor_green"
    private static let blueKey = "accentColor_blue"
    private static let hasCustomKey = "accentColor_hasCustom"
    private static let glassTintKey = "glassTintEnabled"
    private static let glassTintIntensityKey = "glassTintIntensity"
    private static let nowPlayingBlurKey = "nowPlayingBlurredBackground"
    private static let followsArtworkKey = "accentFollowsArtwork"
    static let lightArtworkChoiceKey = "accentArtworkLight"
    static let darkArtworkChoiceKey = "accentArtworkDark"

    @Published var accentColor: Color {
        didSet { save() }
    }

    @Published var hasCustomColor: Bool {
        didSet {
            UserDefaults.standard.set(hasCustomColor, forKey: Self.hasCustomKey)
        }
    }

    /// When true, liquid glass elements are tinted with artwork colors; when false, default glass.
    @Published var glassTintEnabled: Bool {
        didSet {
            UserDefaults.standard.set(glassTintEnabled, forKey: Self.glassTintKey)
        }
    }

    /// How strongly the artwork color tints Liquid Glass elements (0 = none, 1 = full). User-adjustable
    /// so people can dial it down themselves — e.g. in Light Mode, where the glass renders more opaquely.
    @Published var glassTintIntensity: Double {
        didSet {
            UserDefaults.standard.set(glassTintIntensity, forKey: Self.glassTintIntensityKey)
        }
    }

    /// When true, the Now Playing full-screen background blurs the artwork; when false, it stays sharp.
    @Published var nowPlayingBlurredBackground: Bool {
        didSet {
            UserDefaults.standard.set(nowPlayingBlurredBackground, forKey: Self.nowPlayingBlurKey)
        }
    }

    /// When true, the accent follows the cover of the album that's playing.
    @Published var followsArtwork: Bool {
        didSet {
            UserDefaults.standard.set(followsArtwork, forKey: Self.followsArtworkKey)
        }
    }

    /// Which cover color the accent takes in Light Mode.
    @Published var lightArtworkChoice: ArtworkAccentChoice {
        didSet { UserDefaults.standard.set(lightArtworkChoice.rawValue, forKey: Self.lightArtworkChoiceKey) }
    }

    /// Which cover color the accent takes in Dark Mode.
    @Published var darkArtworkChoice: ArtworkAccentChoice {
        didSet { UserDefaults.standard.set(darkArtworkChoice.rawValue, forKey: Self.darkArtworkChoiceKey) }
    }

    /// Vivid colors of the playing album's cover, set by ContentView; nil before anything plays.
    /// The secondary is the primary again when the cover has a single hue.
    @Published var artworkColors: (primary: Color, secondary: Color)?

    func artworkColor(_ choice: ArtworkAccentChoice) -> Color? {
        guard let artworkColors else { return nil }
        return choice == .primary ? artworkColors.primary : artworkColors.secondary
    }

    /// The playing cover's accent: a dynamic color that follows Light/Dark Mode.
    var artworkAccent: Color? {
        guard let light = artworkColor(lightArtworkChoice),
              let dark = artworkColor(darkArtworkChoice) else { return nil }
        #if os(macOS)
        let lightColor = NSColor(light), darkColor = NSColor(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
        #else
        let lightColor = UIColor(light), darkColor = UIColor(dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor })
        #endif
    }

    /// The app-wide tint: the playing album's color, the chosen color, or the system default (nil).
    var effectiveTint: Color? {
        // Until something plays, the chosen color (or the system's) stands in.
        if followsArtwork, let artworkAccent { return artworkAccent }
        return hasCustomColor ? accentColor : nil
    }

    init() {
        self.followsArtwork = UserDefaults.standard.bool(forKey: Self.followsArtworkKey)
        self.lightArtworkChoice = UserDefaults.standard.string(forKey: Self.lightArtworkChoiceKey)
            .flatMap(ArtworkAccentChoice.init(rawValue:)) ?? .primary
        self.darkArtworkChoice = UserDefaults.standard.string(forKey: Self.darkArtworkChoiceKey)
            .flatMap(ArtworkAccentChoice.init(rawValue:)) ?? .primary
        // Glass tint defaults to ON for first launch
        if UserDefaults.standard.object(forKey: Self.glassTintKey) == nil {
            self.glassTintEnabled = true
        } else {
            self.glassTintEnabled = UserDefaults.standard.bool(forKey: Self.glassTintKey)
        }
        // Now Playing blurred background defaults to ON for first launch
        if UserDefaults.standard.object(forKey: Self.nowPlayingBlurKey) == nil {
            self.nowPlayingBlurredBackground = true
        } else {
            self.nowPlayingBlurredBackground = UserDefaults.standard.bool(forKey: Self.nowPlayingBlurKey)
        }
        // Glass tint intensity defaults to full strength for first launch
        if UserDefaults.standard.object(forKey: Self.glassTintIntensityKey) == nil {
            self.glassTintIntensity = 1.0
        } else {
            self.glassTintIntensity = UserDefaults.standard.double(forKey: Self.glassTintIntensityKey)
        }
        let hasCustom = UserDefaults.standard.bool(forKey: Self.hasCustomKey)
        self.hasCustomColor = hasCustom
        if hasCustom {
            let r = UserDefaults.standard.double(forKey: Self.redKey)
            let g = UserDefaults.standard.double(forKey: Self.greenKey)
            let b = UserDefaults.standard.double(forKey: Self.blueKey)
            self.accentColor = Color(red: r, green: g, blue: b)
        } else {
            self.accentColor = .blue
        }
    }

    /// Reads the saved settings again, after a backup has been restored.
    func reload() {
        let fresh = AccentColorManager()
        followsArtwork = fresh.followsArtwork
        lightArtworkChoice = fresh.lightArtworkChoice
        darkArtworkChoice = fresh.darkArtworkChoice
        glassTintEnabled = fresh.glassTintEnabled
        glassTintIntensity = fresh.glassTintIntensity
        nowPlayingBlurredBackground = fresh.nowPlayingBlurredBackground
        hasCustomColor = fresh.hasCustomColor
        accentColor = fresh.accentColor
    }

    private func save() {
        #if os(macOS)
        let cgColor = NSColor(accentColor).cgColor
        guard let components = cgColor.components, components.count >= 3 else { return }
        #else
        guard let components = UIColor(accentColor).cgColor.components,
              components.count >= 3 else { return }
        #endif
        UserDefaults.standard.set(components[0], forKey: Self.redKey)
        UserDefaults.standard.set(components[1], forKey: Self.greenKey)
        UserDefaults.standard.set(components[2], forKey: Self.blueKey)
    }

    func resetToDefault() {
        followsArtwork = false
        hasCustomColor = false
        accentColor = .blue
        UserDefaults.standard.removeObject(forKey: Self.redKey)
        UserDefaults.standard.removeObject(forKey: Self.greenKey)
        UserDefaults.standard.removeObject(forKey: Self.blueKey)
    }
}

extension Color {
    /// A cover's color made usable as an accent on text and controls: never washed out,
    /// never so bright it vanishes on white or so dark it vanishes on black.
    func legibleAccent() -> Color {
        #if os(macOS)
        guard let color = NSColor(self).usingColorSpace(.deviceRGB) else { return self }
        #else
        let color = UIColor(self)
        #endif
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Black-and-white covers: a neutral graphite, not a made-up hue.
        if saturation < 0.15 {
            return Color(white: 0.45)
        }
        return Color(hue: Double(hue),
                     saturation: Double(max(saturation, 0.45)),
                     brightness: Double(min(max(brightness, 0.55), 0.82)))
    }
}
