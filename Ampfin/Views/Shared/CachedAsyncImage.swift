// In Views/Shared/CachedAsyncImage.swift
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    private let url: URL?
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder
    private let targetSize: CGFloat?

    @State private var image: Image?
    @State private var task: Task<Void, Never>?
    @Environment(\.displayScale) private var displayScale

    init(
        url: URL?,
        targetSize: CGFloat? = nil,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.targetSize = targetSize
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                content(image)
            } else {
                placeholder()
            }
        }
        .onAppear {
            loadIfNeeded()
        }
        .onChange(of: url) {
            // cambia URL → reset e ricarica
            image = nil
            task?.cancel()
            task = nil
            loadIfNeeded()
        }
        .onDisappear {
            task?.cancel()
            task = nil
        }
    }

    private func loadIfNeeded() {
        guard image == nil else { return }
        guard let url else { return }

        let key = ImageCacheService.shared.key(for: url)
        if let cached = ImageCacheService.shared.getImage(forKey: key) {
            self.image = Image(platformImage: cached)
            return
        }

        let scale = displayScale
        task = Task.detached(priority: .utility) {
            do {
                let (data, _) = try await JellyfinAPIService.urlSession.data(from: url)

                // Downsample the image to the target display size to reduce memory
                let platform: PlatformImage?
                if let size = targetSize {
                    platform = Self.downsample(data: data, to: size, scale: scale)
                } else {
                    platform = PlatformImage(data: data)
                }

                guard let platform else { return }

                ImageCacheService.shared.setImage(platform, forKey: key)

                await MainActor.run {
                    self.image = Image(platformImage: platform)
                }
            } catch {
                // lascia placeholder
            }
        }
    }

    /// Downsamples image data to a target pixel size using ImageIO for memory efficiency
    private nonisolated static func downsample(data: Data, to pointSize: CGFloat, scale: CGFloat) -> PlatformImage? {
        let maxPixelSize = Int(pointSize * scale)
        // A degenerate target (0 or negative) would ask ImageIO to allocate a zero-size
        // thumbnail slot, which fails and logs a "Failed to create WxH image slot" warning.
        guard maxPixelSize > 0 else { return PlatformImage(data: data) }

        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary) else {
            return PlatformImage(data: data)
        }

        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions as CFDictionary) else {
            return PlatformImage(data: data)
        }

        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}
