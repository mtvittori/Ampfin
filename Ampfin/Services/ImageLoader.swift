import SwiftUI

/// Loads the first of several candidate images that the server actually has.
/// Artists may lack a backdrop or a photo, so callers pass a fallback list.
actor ImageLoader {
    static let shared = ImageLoader()

    /// URLs that answered with an error, so scrolling back doesn't ask again.
    private var missing = Set<URL>()

    func firstImage(from urls: [URL]) async -> PlatformImage? {
        for url in urls where !missing.contains(url) {
            let key = ImageCacheService.shared.key(for: url)
            if let cached = ImageCacheService.shared.getImage(forKey: key) {
                return cached
            }
            do {
                let (data, response) = try await JellyfinAPIService.urlSession.data(from: url)
                if Task.isCancelled { return nil }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let image = PlatformImage(data: data) else {
                    missing.insert(url)
                    continue
                }
                ImageCacheService.shared.setImage(image, forKey: key)
                return image
            } catch {
                // Network hiccup or cancellation: try again next time.
                if Task.isCancelled { return nil }
            }
        }
        return nil
    }
}

enum TimeFormat {
    static func time(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
