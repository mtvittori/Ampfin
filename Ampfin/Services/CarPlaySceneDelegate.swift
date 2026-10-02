#if os(iOS)
import UIKit
import CarPlay

class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    private var viewModel: JellyfinViewModel? {
        JellyfinViewModel.shared
    }

    // MARK: - Scene Lifecycle

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        guard let viewModel = viewModel, viewModel.isLoggedIn else {
            showNotLoggedIn(interfaceController)
            return
        }

        setupTabs(interfaceController, viewModel: viewModel)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }

    // MARK: - Not Logged In

    private func showNotLoggedIn(_ controller: CPInterfaceController) {
        let item = CPListItem(text: "Apri amplifin su iPhone per accedere", detailText: nil)
        let section = CPListSection(items: [item])
        let template = CPListTemplate(title: "amplifin", sections: [section])
        template.tabTitle = "amplifin"
        template.tabImage = UIImage(systemName: "music.note")
        controller.setRootTemplate(template, animated: false, completion: nil)
    }

    // MARK: - Tab Setup

    private func setupTabs(_ controller: CPInterfaceController, viewModel: JellyfinViewModel) {
        let homeTab = makeHomeTab(viewModel: viewModel)
        let libraryTab = makeLibraryTab(viewModel: viewModel)
        let favoritesTab = makeFavoritesTab(viewModel: viewModel)

        let nowPlayingTab = CPNowPlayingTemplate.shared
        nowPlayingTab.tabTitle = "In Riproduzione"
        nowPlayingTab.tabImage = UIImage(systemName: "play.circle")

        let tabBar = CPTabBarTemplate(templates: [homeTab, libraryTab, favoritesTab, nowPlayingTab])
        controller.setRootTemplate(tabBar, animated: true, completion: nil)
    }

    // MARK: - Home Tab (Recently Played)

    private func makeHomeTab(viewModel: JellyfinViewModel) -> CPListTemplate {
        let items = viewModel.recentlyPlayedAlbums.prefix(12).map { album in
            makeAlbumListItem(album: album, viewModel: viewModel)
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Home", sections: [section])
        template.tabTitle = "Home"
        template.tabImage = UIImage(systemName: "house")

        // Refresh data when tab is loaded
        Task { @MainActor in
            await viewModel.fetchRecentlyPlayedAlbumsIfNeeded()
            let refreshedItems = viewModel.recentlyPlayedAlbums.prefix(12).map { album in
                self.makeAlbumListItem(album: album, viewModel: viewModel)
            }
            template.updateSections([CPListSection(items: refreshedItems)])
        }

        return template
    }

    // MARK: - Library Tab

    private func makeLibraryTab(viewModel: JellyfinViewModel) -> CPListTemplate {
        let albumsItem = CPListItem(text: "Album", detailText: "\(viewModel.albums.count) album")
        albumsItem.accessoryType = .disclosureIndicator
        albumsItem.handler = { [weak self] _, completion in
            self?.showAlbumsList(viewModel: viewModel)
            completion()
        }

        let artistsItem = CPListItem(text: "Artisti", detailText: "\(viewModel.artists.count) artisti")
        artistsItem.accessoryType = .disclosureIndicator
        artistsItem.handler = { [weak self] _, completion in
            self?.showArtistsList(viewModel: viewModel)
            completion()
        }

        let tracksItem = CPListItem(text: "Brani", detailText: "\(viewModel.audioItems.count) brani")
        tracksItem.accessoryType = .disclosureIndicator
        tracksItem.handler = { [weak self] _, completion in
            self?.showTracksList(viewModel: viewModel, tracks: viewModel.audioItems, title: "Brani")
            completion()
        }

        let section = CPListSection(items: [albumsItem, artistsItem, tracksItem])
        let template = CPListTemplate(title: "Libreria", sections: [section])
        template.tabTitle = "Libreria"
        template.tabImage = UIImage(systemName: "music.note.list")
        return template
    }

    // MARK: - Favorites Tab

    private func makeFavoritesTab(viewModel: JellyfinViewModel) -> CPListTemplate {
        let favAlbums = viewModel.favoriteAlbums
        let favTracks = viewModel.favoriteTracks

        let albumItems: [CPListItem] = favAlbums.prefix(12).map { album in
            makeAlbumListItem(album: album, viewModel: viewModel)
        }

        let trackItems: [CPListItem] = favTracks.prefix(12).map { track in
            makeTrackListItem(track: track, queue: Array(favTracks), viewModel: viewModel)
        }

        var sections: [CPListSection] = []
        if !albumItems.isEmpty {
            sections.append(CPListSection(items: albumItems, header: "Album Preferiti", sectionIndexTitle: nil))
        }
        if !trackItems.isEmpty {
            sections.append(CPListSection(items: trackItems, header: "Brani Preferiti", sectionIndexTitle: nil))
        }
        if sections.isEmpty {
            let emptyItem = CPListItem(text: "Nessun preferito", detailText: "Aggiungi preferiti dall'app")
            sections.append(CPListSection(items: [emptyItem]))
        }

        let template = CPListTemplate(title: "Preferiti", sections: sections)
        template.tabTitle = "Preferiti"
        template.tabImage = UIImage(systemName: "heart")
        return template
    }

    // MARK: - Sub-views

    private func showAlbumsList(viewModel: JellyfinViewModel) {
        let items = viewModel.albums.prefix(100).map { album in
            makeAlbumListItem(album: album, viewModel: viewModel)
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Album", sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showArtistsList(viewModel: JellyfinViewModel) {
        let items: [CPListItem] = viewModel.artists.prefix(100).map { artist in
            let item = CPListItem(text: artist.Name, detailText: nil)
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showArtistAlbums(artist: artist, viewModel: viewModel)
                completion()
            }
            return item
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: "Artisti", sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showArtistAlbums(artist: ArtistItem, viewModel: JellyfinViewModel) {
        let artistAlbums = viewModel.albums.filter { album in
            album.AlbumArtist == artist.Name
        }
        let items = artistAlbums.map { album in
            makeAlbumListItem(album: album, viewModel: viewModel)
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: artist.Name, sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func showAlbumTracks(album: AlbumItem, viewModel: JellyfinViewModel) {
        // Show a loading template
        let loadingItem = CPListItem(text: "Caricamento...", detailText: nil)
        let loadingTemplate = CPListTemplate(title: album.Name, sections: [CPListSection(items: [loadingItem])])
        interfaceController?.pushTemplate(loadingTemplate, animated: true, completion: nil)

        Task { @MainActor in
            let tracks = await viewModel.fetchAlbumTracksDirectly(albumId: album.Id)
            let items = tracks.map { track in
                self.makeTrackListItem(track: track, queue: tracks, viewModel: viewModel)
            }
            let section = CPListSection(items: items)
            loadingTemplate.updateSections([section])
        }
    }

    private func showTracksList(viewModel: JellyfinViewModel, tracks: [AudioItem], title: String) {
        let displayTracks = Array(tracks.prefix(100))
        let items = displayTracks.map { track in
            makeTrackListItem(track: track, queue: displayTracks, viewModel: viewModel)
        }
        let section = CPListSection(items: items)
        let template = CPListTemplate(title: title, sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - List Item Factories

    private func makeAlbumListItem(album: AlbumItem, viewModel: JellyfinViewModel) -> CPListItem {
        let detail = album.AlbumArtist ?? ""
        let item = CPListItem(text: album.Name, detailText: detail)
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.showAlbumTracks(album: album, viewModel: viewModel)
            completion()
        }

        // Async artwork
        loadArtwork(itemId: album.Id, viewModel: viewModel) { image in
            item.setImage(image)
        }

        return item
    }

    private func makeTrackListItem(track: AudioItem, queue: [AudioItem], viewModel: JellyfinViewModel) -> CPListItem {
        let detail = track.mainArtistName ?? ""
        let item = CPListItem(text: track.Name, detailText: detail)
        item.handler = { [weak self] _, completion in
            viewModel.playerManager?.play(item: track, in: queue)
            // Push Now Playing after starting playback
            let nowPlaying = CPNowPlayingTemplate.shared
            self?.interfaceController?.pushTemplate(nowPlaying, animated: true, completion: nil)
            completion()
        }

        // Async artwork
        let artworkId = track.AlbumId ?? track.Id
        loadArtwork(itemId: artworkId, viewModel: viewModel) { image in
            item.setImage(image)
        }

        return item
    }

    // MARK: - Artwork Loading

    private func loadArtwork(itemId: String, viewModel: JellyfinViewModel, completion: @escaping (UIImage) -> Void) {
        guard let url = viewModel.artworkURL(for: itemId, size: 120) else { return }

        Task.detached(priority: .utility) {
            do {
                let (data, _) = try await JellyfinAPIService.urlSession.data(from: url)
                if let image = UIImage(data: data) {
                    await MainActor.run {
                        completion(image)
                    }
                }
            } catch {
                // Artwork loading failed silently
            }
        }
    }
}
#endif
