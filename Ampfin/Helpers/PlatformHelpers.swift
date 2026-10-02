// PlatformHelpers.swift
// Cross-platform type aliases and helpers

import SwiftUI

#if os(macOS)
import AppKit
public typealias PlatformImage = NSImage
#else
import UIKit
public typealias PlatformImage = UIImage
#endif

// MARK: - SwiftUI Image convenience initializer

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

// MARK: - Cross-platform Color helper

extension Color {
    static var platformControlBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(UIColor.secondarySystemBackground)
        #endif
    }
}

// MARK: - Vibrant color extraction

extension PlatformImage {
    /// Extracts the most vibrant, high-contrast color from the image.
    /// Samples a grid of pixels, converts to HSB, and picks the most saturated color
    /// with enough brightness to look good as a glass tint.
    func averageColor() -> Color? {
        guard let cgImage = self.cgImage else { return nil }

        // Scale down to 16x16 for sampling
        let sampleSize = 16
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))

        guard let data = context.data else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let totalPixels = sampleSize * sampleSize

        // Collect all pixel colors with their HSB values
        struct PixelHSB {
            let r, g, b: Double
            let hue, saturation, brightness: Double

            // Score: prefer saturated + medium-to-high brightness colors
            var vibrancy: Double {
                saturation * (0.3 + 0.7 * brightness)
            }
        }

        var candidates: [PixelHSB] = []
        candidates.reserveCapacity(totalPixels)

        for i in 0..<totalPixels {
            let offset = i * 4
            let r = Double(pixels[offset]) / 255.0
            let g = Double(pixels[offset + 1]) / 255.0
            let b = Double(pixels[offset + 2]) / 255.0

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC

            let brightness = maxC
            let saturation = maxC > 0 ? delta / maxC : 0

            var hue: Double = 0
            if delta > 0 {
                if maxC == r {
                    hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
                } else if maxC == g {
                    hue = (b - r) / delta + 2
                } else {
                    hue = (r - g) / delta + 4
                }
                hue /= 6
                if hue < 0 { hue += 1 }
            }

            let pixel = PixelHSB(r: r, g: g, b: b, hue: hue, saturation: saturation, brightness: brightness)
            candidates.append(pixel)
        }

        // Filter out near-gray (low saturation) and very dark/bright pixels
        let vibrant = candidates.filter { $0.saturation > 0.2 && $0.brightness > 0.15 && $0.brightness < 0.95 }

        if let best = vibrant.max(by: { $0.vibrancy < $1.vibrancy }) {
            // Boost saturation slightly for a more vivid tint
            let boostedS = min(best.saturation * 1.2, 1.0)
            let boostedB = max(min(best.brightness, 0.85), 0.4)
            return Color(hue: best.hue, saturation: boostedS, brightness: boostedB)
        }

        // Fallback: if no vibrant pixel, use the brightest one with any saturation
        let fallback = candidates.filter { $0.saturation > 0.05 }.max(by: { $0.vibrancy < $1.vibrancy })
        if let fb = fallback {
            return Color(hue: fb.hue, saturation: min(fb.saturation * 1.5, 1.0), brightness: max(min(fb.brightness, 0.85), 0.4))
        }

        // Last resort: plain average
        let avgR = candidates.reduce(0.0) { $0 + $1.r } / Double(totalPixels)
        let avgG = candidates.reduce(0.0) { $0 + $1.g } / Double(totalPixels)
        let avgB = candidates.reduce(0.0) { $0 + $1.b } / Double(totalPixels)
        return Color(red: avgR, green: avgG, blue: avgB)
    }

    #if os(macOS)
    var cgImage: CGImage? {
        cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    #endif
}

// MARK: - Color luminance helper

extension Color {
    /// Returns true if this color is perceptually light (white text would be hard to read on it).
    /// Uses relative luminance formula (ITU-R BT.709).
    func isLight() -> Bool {
        #if os(macOS)
        let cgColor = NSColor(self).cgColor
        guard let components = cgColor.components, components.count >= 3 else { return false }
        #else
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else { return false }
        #endif
        let r = components[0]
        let g = components[1]
        let b = components[2]
        // Relative luminance
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6
    }
}
