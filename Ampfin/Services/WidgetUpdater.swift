// WidgetUpdater.swift
// Keeps the widgets' snapshot (WidgetSnapshot, in the App Group) in step with the
// app: song playing and its cover's color, what's next, recent and favorite albums.
// Covers are saved there at 300 px, so widgets never download them. Only the
// widget kinds whose content changed are reloaded.

import Foundation
import Combine
import WidgetKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
final class WidgetUpdater {
    static let shared = WidgetUpdater()

    private var cancellables = Set<AnyCancellable>()
    private weak var viewModel: JellyfinViewModel?
    private var last: WidgetSnapshot?
    private var running: Task<Void, Never>?
    private var queued = false

    /// Called after every login: the player is new each time, so subscribe again.
    func start(viewModel: JellyfinViewModel) {
        cancellables.removeAll()
        self.viewModel = viewModel
        // Throttled, not debounced: the player publishes its time twice a second, and a
        // debounce would never fire while music plays. Unchanged snapshots are skipped.
        viewModel.objectWillChange
            .merge(with: viewModel.playerManager.objectWillChange)
            .throttle(for: .seconds(1.5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.schedule() }
            .store(in: &cancellables)
        schedule()
    }

    private func schedule() {
        guard running == nil else { queued = true; return }
        running = Task {
            await update()
            running = nil
            if queued { queued = false; schedule() }
        }
    }

    private func update() async {
        // Read on the next turn, once the change that triggered this has landed.
        await Task.yield()
        guard let vm = viewModel else { return }

        func track(_ item: AudioItem) -> WidgetSnapshot.Track {
            WidgetSnapshot.Track(id: item.Id, title: item.Name, artist: vm.artistName(for: item) ?? "",
                                 album: item.Album ?? "", albumId: item.AlbumId ?? item.Id)
        }
        func album(_ item: AlbumItem) -> WidgetSnapshot.Album {
            WidgetSnapshot.Album(id: item.Id, title: item.Name, artist: item.AlbumArtist ?? "")
        }

        var snapshot = WidgetSnapshot()
        snapshot.nowPlaying = vm.currentlyPlayingItem.map(track)
        snapshot.isPlaying = vm.isPlaying
        snapshot.upNext = Array(vm.playerManager.upNext.prefix(4)).map(track)
        let recent = vm.recentlyPlayedAlbums.isEmpty ? vm.recentlyAddedAlbums : vm.recentlyPlayedAlbums
        snapshot.recentAlbums = Array(recent.prefix(6)).map(album)
        snapshot.favoriteAlbums = Array(vm.favoriteAlbums.prefix(6)).map(album)
        // Same album as before: same color, no need to look at the cover again.
        let samePlaying = last?.nowPlaying?.albumId == snapshot.nowPlaying?.albumId && last != nil
        snapshot.palette = samePlaying ? (last?.palette ?? .neutral) : .neutral

        // Covers first (the palette comes from the playing one), then the file.
        let ids = Set([snapshot.nowPlaying?.albumId].compactMap { $0 }
                      + snapshot.upNext.map(\.albumId) + snapshot.recentAlbums.map(\.id) + snapshot.favoriteAlbums.map(\.id))
        for id in ids {
            let needsColor = id == snapshot.nowPlaying?.albumId && !samePlaying
            if let image = await saveCover(for: id, readBack: needsColor, viewModel: vm), needsColor,
               let colors = HeroPalette(image: image) {
                snapshot.palette = WidgetSnapshot.Palette(red: colors.rgb[0], green: colors.rgb[1], blue: colors.rgb[2],
                                                          isLight: colors.isLight)
            }
        }

        var comparable = snapshot
        comparable.updated = last?.updated ?? snapshot.updated
        guard comparable != last else { return }
        let previous = last
        last = snapshot
        WidgetStore.save(snapshot)

        if previous?.nowPlaying != snapshot.nowPlaying || previous?.isPlaying != snapshot.isPlaying
            || previous?.upNext != snapshot.upNext || previous?.palette != snapshot.palette {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.nowPlaying)
        }
        if previous?.recentAlbums != snapshot.recentAlbums {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.recent)
        }
        if previous?.favoriteAlbums != snapshot.favoriteAlbums {
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetKinds.favorites)
        }
    }

    /// Writes a 300 px JPEG of the cover into the App Group once. Returns the image when
    /// it had to be loaded now, or when `readBack` asks for an already saved one.
    private func saveCover(for id: String, readBack: Bool, viewModel vm: JellyfinViewModel) async -> PlatformImage? {
        guard let file = WidgetStore.artURL(for: id), let directory = WidgetStore.artDirectory else { return nil }
        if FileManager.default.fileExists(atPath: file.path) {
            return readBack ? (try? Data(contentsOf: file)).flatMap(PlatformImage.init(data:)) : nil
        }
        guard let url = vm.artworkURL(for: id, size: 300),
              let image = await ZuneImageLoader.shared.firstImage(from: [url]) else { return nil }
        let data = await Task.detached(priority: .utility) { Self.jpeg(image) }.value
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data { try? data.write(to: file, options: .atomic) }
        return image
    }

    private nonisolated static func jpeg(_ image: PlatformImage) -> Data? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
        #else
        let side: CGFloat = 300
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return small.jpegData(compressionQuality: 0.8)
        #endif
    }
}
