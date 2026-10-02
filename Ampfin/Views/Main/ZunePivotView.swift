// ZunePivotView.swift
// Windows Phone pivot navigation, used instead of the tab bar when "Stile Zune" is on:
// the section titles sit in a row at the top, huge, and the pages swipe sideways.

import SwiftUI

#if os(iOS)
struct ZunePivotView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Binding var selection: ContentView.SidebarItem

    @State private var path = NavigationPath()
    @State private var pageID: ContentView.SidebarItem?
    /// Scroll position in pages (1.5 = halfway between the second and third).
    @State private var progress: CGFloat = 0
    @State private var barsHeight: CGFloat = 0

    static let pages: [ContentView.SidebarItem] = [.home, .tracks, .albums, .artists, .search]
    private let headerHeight: CGFloat = 76

    var body: some View {
        NavigationStack(path: $path) {
            // Each page's photo reaches up past the header and the navigation bar
            // to the top of the screen.
            pager(backdropReach: headerHeight + barsHeight)
                .padding(.top, headerHeight)
                // An overlay, so the title row (wider than the screen) can't widen the pages.
                .overlay(alignment: .topLeading) {
                    ZunePivotHeader(titles: Self.pages.map { $0.title.lowercased() }, progress: progress) { index in
                        withAnimation(.easeInOut(duration: 0.35)) {
                            pageID = Self.pages[index]
                        }
                    }
                    .frame(height: headerHeight, alignment: .bottom)
                }
                .background {
                    // Full-screen, so its insets measure status bar plus navigation bar.
                    Color.black
                        .ignoresSafeArea()
                        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { barsHeight = $0 }
                }
            .iOSToolbar(viewModel: viewModel)
            .zuneChrome()
            .navigationDestination(for: ArtistItem.self) { artist in
                ArtistAlbumsView(artist: artist)
            }
            .navigationDestination(for: AlbumItem.self) { album in
                AlbumTracksListView(album: album)
            }
        }
        .onAppear {
            pageID = selection
        }
        .onChange(of: pageID) {
            if let pageID, pageID != selection { selection = pageID }
        }
        .onChange(of: selection) {
            if pageID != selection { pageID = selection }
        }
        #if DEBUG
        // Test-only: `-provaArtista <name>` opens that artist's page.
        .task(id: viewModel.artists.count) {
            if path.isEmpty, let name = UserDefaults.standard.string(forKey: "provaArtista"),
               let artist = viewModel.artist(named: name) {
                path.append(artist)
            }
        }
        #endif
    }

    private func pager(backdropReach: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                ForEach(Array(Self.pages.enumerated()), id: \.element) { index, page in
                    pageView(page)
                        .environment(\.zunePivotHeaderHeight, headerHeight)
                        .environment(\.zuneBackdropReach, backdropReach)
                        .environment(\.zuneBackdropPaused, Int(progress.rounded()) != index)
                        .containerRelativeFrame(.horizontal)
                        .id(page)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: $pageID)
        // Lets each page's photo reach up behind the header and the bars.
        .scrollClipDisabled()
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.x / max(geo.containerSize.width, 1)
        } action: { _, newValue in
            progress = newValue
        }
    }

    @ViewBuilder
    private func pageView(_ page: ContentView.SidebarItem) -> some View {
        switch page {
        case .home: HomeView()
        case .tracks: TracksView()
        case .albums: AlbumsView()
        case .artists: ArtistsView()
        default: SearchResultsView(query: $viewModel.globalSearchQuery)
        }
    }
}

/// The row of section titles. It slides with the pages so the current title is
/// always at the left edge, bright, with the next ones dimmed and running off screen.
private struct ZunePivotHeader: View {
    let titles: [String]
    let progress: CGFloat
    let onSelect: (Int) -> Void

    @State private var widths: [Int: CGFloat] = [:]
    private let spacing: CGFloat = 24

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: spacing) {
            ForEach(titles.indices, id: \.self) { index in
                Text(titles[index])
                    .font(.zune(56, .light, relativeTo: .largeTitle))
                    .foregroundStyle(.white.opacity(opacity(for: index)))
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { widths[index] = $0 }
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(index) }
                    .accessibilityAddTraits(isCurrent(index) ? [.isButton, .isSelected] : .isButton)
            }
        }
        .fixedSize()
        .offset(x: 16 - scrollOffset)
    }

    private func isCurrent(_ index: Int) -> Bool {
        Int(progress.rounded()) == index
    }

    private func opacity(for index: Int) -> Double {
        0.4 + 0.6 * max(0, 1 - abs(Double(progress) - Double(index)))
    }

    /// Distance from the first title to the start of title `index`.
    private func start(of index: Int) -> CGFloat {
        (0..<index).reduce(0) { $0 + (widths[$1] ?? 0) + spacing }
    }

    private var scrollOffset: CGFloat {
        guard !titles.isEmpty else { return 0 }
        let clamped = min(max(progress, 0), CGFloat(titles.count - 1))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, titles.count - 1)
        let fraction = clamped - CGFloat(lower)
        return start(of: lower) + (start(of: upper) - start(of: lower)) * fraction
    }
}
#endif
