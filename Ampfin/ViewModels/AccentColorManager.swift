import SwiftUI

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
    private static let zuneStyleKey = "zuneStyleEnabled"

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

    /// When true, artists and Now Playing use the Zune look: the artist's photo
    /// panning slowly behind huge lowercase type.
    @Published var zuneStyleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(zuneStyleEnabled, forKey: Self.zuneStyleKey)
        }
    }

    init() {
        // Zune style defaults to ON for first launch
        if UserDefaults.standard.object(forKey: Self.zuneStyleKey) == nil {
            self.zuneStyleEnabled = true
        } else {
            self.zuneStyleEnabled = UserDefaults.standard.bool(forKey: Self.zuneStyleKey)
        }
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
        hasCustomColor = false
        accentColor = .blue
        UserDefaults.standard.removeObject(forKey: Self.redKey)
        UserDefaults.standard.removeObject(forKey: Self.greenKey)
        UserDefaults.standard.removeObject(forKey: Self.blueKey)
    }
}
