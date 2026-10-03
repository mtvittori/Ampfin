// In Services/ImageCacheService.swift
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

final class ImageCacheService {
    static let shared = ImageCacheService()

    private let memoryCache = NSCache<NSString, PlatformImage>()
    private let fileManager = FileManager.default
    private let diskCachePath: URL

    private init() {
        if let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            self.diskCachePath = cacheDirectory.appendingPathComponent("ImageCache")
            if !fileManager.fileExists(atPath: self.diskCachePath.path) {
                try? fileManager.createDirectory(at: self.diskCachePath, withIntermediateDirectories: true, attributes: nil)
            }
        } else {
            self.diskCachePath = URL(fileURLWithPath: "")
        }
        memoryCache.countLimit = 500
        // Limit total memory cost to ~100 MB (assuming average ~200KB per image)
        memoryCache.totalCostLimit = 100 * 1024 * 1024
    }

    /// Memory only: safe on the main thread. `getImage` may read and decode from disk,
    /// so call it off the main thread.
    func memoryImage(forKey key: String) -> PlatformImage? {
        memoryCache.object(forKey: key as NSString)
    }

    /// The raw bytes on disk, for callers that decode (and downsample) themselves.
    func diskData(forKey key: String) -> Data? {
        try? Data(contentsOf: diskCachePath.appendingPathComponent(key))
    }

    func getImage(forKey key: String) -> PlatformImage? {
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        let fileURL = diskCachePath.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }

        if let image = PlatformImage(data: data) {
            memoryCache.setObject(image, forKey: key as NSString)
            return image
        }

        return nil
    }

    func setImage(_ image: PlatformImage, forKey key: String, toDisk: Bool = true) {
        memoryCache.setObject(image, forKey: key as NSString)
        guard toDisk else { return }

        DispatchQueue.global(qos: .background).async {
            let fileURL = self.diskCachePath.appendingPathComponent(key)

            #if os(macOS)
            // Use JPEG instead of TIFF for much smaller disk footprint
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
            else { return }
            try? data.write(to: fileURL)
            #else
            let data = image.jpegData(compressionQuality: 0.85) ?? image.pngData()
            guard let data else { return }
            try? data.write(to: fileURL)
            #endif
        }
    }

    func clearAll() {
        memoryCache.removeAllObjects()
        try? fileManager.removeItem(at: diskCachePath)
        try? fileManager.createDirectory(at: diskCachePath, withIntermediateDirectories: true)
    }

    func diskSize() -> Int64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: diskCachePath,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    func key(for url: URL) -> String {
        // Use SHA256-style hex hash via simple hashing for file-safe keys
        // (base64 can contain "/" which is not file-safe)
        let input = url.absoluteString
        var hash: UInt64 = 5381
        for byte in input.utf8 {
            hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
        }
        return String(format: "%016llx", hash)
    }
}
