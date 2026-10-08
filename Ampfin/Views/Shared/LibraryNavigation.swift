// LibraryNavigation.swift
// "Vai all'artista" and "Vai all'album" from anywhere (song menus, the player): the
// request switches to the Artisti or Album tab and opens the page there. Also the
// letter groups used by the song and artist lists and their side index.

import SwiftUI

// MARK: - Navigation requests

/// Asks ContentView to show an artist or an album page in its own tab.
final class LibraryNavigator: ObservableObject {
    static let shared = LibraryNavigator()

    enum Destination: Equatable {
        case artist(ArtistItem)
        case album(AlbumItem)
    }

    struct Request: Equatable {
        let id = UUID()
        let destination: Destination
    }

    @Published private(set) var request: Request?

    func show(_ destination: Destination) {
        request = Request(destination: destination)
    }
}

extension JellyfinViewModel {
    /// The artist page for a song: its main artist, or the album's artist for untagged files.
    func artistItem(for track: AudioItem) -> ArtistItem? {
        artist(named: artistName(for: track))
    }

    func albumItem(for track: AudioItem) -> AlbumItem? {
        guard let albumId = track.AlbumId else { return nil }
        return albums.first { $0.Id == albumId }  // on a tap only
    }
}

/// "Aggiungi a playlist", "Vai all'artista" and "Vai all'album" for a song's long-press
/// or "⋯" menu. SwiftUI builds a row's menu with the row, at every row that scrolls into
/// view, so nothing is looked up here: the artist and album pages are found on the tap.
struct TrackNavigationMenuItems: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let track: AudioItem
    var showsAlbum = true

    var body: some View {
        #if os(iOS)
        AddToPlaylistMenu(tracks: [track])
        Button {
            if let artist = viewModel.artistItem(for: track) {
                LibraryNavigator.shared.show(.artist(artist))
            } else {
                QueueFeedback.shared.show("Artista non trovato", systemImage: "music.mic")
            }
        } label: {
            Label("Vai all'artista", systemImage: "music.mic")
        }
        if showsAlbum, track.AlbumId != nil {
            Button {
                if let album = viewModel.albumItem(for: track) {
                    LibraryNavigator.shared.show(.album(album))
                } else {
                    QueueFeedback.shared.show("Album non trovato", systemImage: "square.stack")
                }
            } label: {
                Label("Vai all'album", systemImage: "square.stack")
            }
        }
        #endif
    }
}

// MARK: - Letter groups

/// A run of items under one letter, for sectioned lists with the side index.
struct LetterSection<Item: Identifiable>: Identifiable {
    let letter: String
    let items: [Item]
    var id: String { letter }
}

enum LetterIndex {
    /// "A"…"Z" by the first letter, accents folded ("É" is under "E"); anything else is "#".
    static func letter(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "#" }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased()
        guard let scalar = folded.unicodeScalars.first, folded.unicodeScalars.count == 1,
              ("A"..."Z").contains(Character(scalar)) else { return "#" }
        return folded
    }

    /// Groups items by letter, A to Z and "#" last, keeping their order inside each letter.
    static func sections<Item: Identifiable>(_ items: [Item], name: (Item) -> String) -> [LetterSection<Item>] {
        var groups: [String: [Item]] = [:]
        for item in items {
            groups[letter(for: name(item)), default: []].append(item)
        }
        return groups.keys
            .sorted { lhs, rhs in
                if lhs == "#" { return false }
                if rhs == "#" { return true }
                return lhs < rhs
            }
            .map { LetterSection(letter: $0, items: groups[$0] ?? []) }
    }
}

/// A flat list of letter rows and items, so a List can jump to a letter's row: the
/// rows are the ForEach's own ids, which scrolling to a letter needs.
enum LetterRow<Item: Identifiable>: Identifiable where Item.ID == String {
    case letter(String)
    case item(Item)

    var id: String {
        switch self {
        case .letter(let letter): return LetterIndex.rowId(letter)
        case .item(let item): return item.id
        }
    }

    static func rows(_ sections: [LetterSection<Item>]) -> [LetterRow] {
        sections.flatMap { [LetterRow.letter($0.letter)] + $0.items.map(LetterRow.item) }
    }
}

extension LetterIndex {
    static let all = (65...90).map { String(UnicodeScalar($0)!) } + ["#"]
    static func rowId(_ letter: String) -> String { "letter-\(letter)" }

    /// The letter to go to for a touched one: itself, or the next one that has items.
    static func target(for letter: String, in available: [String]) -> String? {
        guard let start = all.firstIndex(of: letter) else { return available.first }
        return all[start...].first(where: available.contains) ?? available.last
    }
}

/// The letter row of a sectioned List.
struct LetterHeaderRow: View {
    let letter: String

    var body: some View {
        Text(letter)
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 2, trailing: 20))
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - The A–Z strip

/// Settings → Elenchi → Indice lettere. Classic: iOS's own index on the lists (smoothest),
/// always there. A scomparsa: Ampfin's strip, shown only while scrolling.
enum LetterIndexStyle: String, CaseIterable, Identifiable {
    case classic, autoHide

    static let storageKey = "letterIndexStyle"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .classic: return "Classico"
        case .autoHide: return "A scomparsa"
        }
    }
}

extension View {
    /// Ampfin's A–Z strip on the right edge. "A scomparsa": it shows while the content
    /// scrolls and fades out a moment after it stops; "Classico": always there (for the
    /// album grid, which has no index of iOS's own). `letters` are those with items;
    /// `jump` scrolls to one of them. No letters, no strip.
    func letterScrubber(letters: [String], jump: @escaping (String) -> Void) -> some View {
        modifier(LetterScrubberOverlay(letters: letters, jump: jump))
    }

    /// iOS's own index for a sectioned List, when the style is Classico.
    @ViewBuilder
    func systemLetterIndex(_ visible: Bool) -> some View {
        #if os(iOS)
        self.listSectionIndexVisibility(visible ? .visible : .hidden)
        #else
        self
        #endif
    }
}

/// Scroll and drag state of the A–Z strip. It changes at every scroll gesture, so only the
/// strip and the bubble observe it: the list and its rows are not redrawn for it.
@MainActor
final class LetterScrubberModel: ObservableObject {
    @Published var scrolling = false
    @Published var dragging = false
    @Published var current: String?
    private var hideTask: Task<Void, Never>?

    /// Called on phase changes only (not per frame): shows the strip while the content moves.
    func scrollPhaseChanged(_ phase: ScrollPhase) {
        if phase == .idle {
            scheduleHide()
        } else {
            cancelHide()
            if !scrolling { scrolling = true }
        }
    }

    func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    /// Hides the strip 1.5 s after the scrolling or the drag stops.
    func scheduleHide() {
        cancelHide()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, !dragging else { return }
            scrolling = false
        }
    }
}

struct LetterScrubberOverlay: ViewModifier {
    let letters: [String]
    let jump: (String) -> Void

    @AppStorage(LetterIndexStyle.storageKey) private var style = LetterIndexStyle.classic.rawValue
    // A reference held in @State: the modifier's body never reads the model's properties,
    // so changing them does not re-evaluate it (nor the list it decorates).
    @State private var model = LetterScrubberModel()

    private var autoHide: Bool { style == LetterIndexStyle.autoHide.rawValue }

    @ViewBuilder
    func body(content: Content) -> some View {
        if letters.isEmpty {
            content
        } else if autoHide {
            decorated(content)
                .onScrollPhaseChange { _, phase in
                    model.scrollPhaseChanged(phase)
                }
        } else {
            // Always there: nothing follows the scrolling.
            decorated(content)
        }
    }

    private func decorated(_ content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                LetterStrip(letters: letters, jump: jump, autoHide: autoHide, model: model)
            }
            // The letter being touched, big in the middle, as in Contacts.
            .overlay {
                LetterScrubBubble(model: model)
            }
    }
}

/// The A–Z strip. The animation stays on it: on the whole list it wrapped every row update.
private struct LetterStrip: View {
    let letters: [String]
    let jump: (String) -> Void
    let autoHide: Bool
    @ObservedObject var model: LetterScrubberModel
    private let rowHeight: CGFloat = 15

    private var shown: Bool { !autoHide || model.scrolling || model.dragging }

    var body: some View {
        ZStack {
            if shown {
                strip
                    .padding(.trailing, 2)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shown)
        .sensoryFeedback(.selection, trigger: model.current)
    }

    private var strip: some View {
        VStack(spacing: 0) {
            ForEach(LetterIndex.all, id: \.self) { letter in
                Text(letter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(letters.contains(letter) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .frame(width: 22, height: rowHeight)
            }
        }
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    model.cancelHide()
                    // Written once per drag, not per touch sample.
                    if !model.dragging { model.dragging = true }
                    let index = Int((value.location.y - 8) / rowHeight)
                    let touched = LetterIndex.all[min(max(index, 0), LetterIndex.all.count - 1)]
                    guard let target = LetterIndex.target(for: touched, in: letters), target != model.current else { return }
                    model.current = target
                    jump(target)
                }
                .onEnded { _ in
                    model.dragging = false
                    model.current = nil
                    if autoHide { model.scheduleHide() }
                }
        )
        .accessibilityElement()
        .accessibilityLabel("Indice alfabetico")
        .accessibilityAdjustableAction { direction in
            let index = model.current.flatMap(letters.firstIndex(of:)) ?? -1
            let next = direction == .increment ? index + 1 : index - 1
            guard letters.indices.contains(next) else { return }
            model.current = letters[next]
            jump(letters[next])
        }
    }
}

/// The big letter under the finger while dragging the strip.
private struct LetterScrubBubble: View {
    @ObservedObject var model: LetterScrubberModel

    var body: some View {
        ZStack {
            if model.dragging, let current = model.current {
                Text(current)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .frame(width: 84, height: 84)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.2), value: model.dragging)
    }
}
