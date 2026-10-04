// QueueActions.swift
// "Riproduci dopo" and "Aggiungi alla coda", as in Apple Music: menu items for songs
// and albums, list swipe actions, and the little confirmation that drops in at the top.

import SwiftUI

// MARK: - Confirmation

/// The banner that confirms a queue change ("Riprodotto dopo", "Aggiunto alla coda").
final class QueueFeedback: ObservableObject {
    static let shared = QueueFeedback()

    struct Message: Equatable {
        let id = UUID()
        let text: String
        let systemImage: String
    }

    @Published private(set) var message: Message?
    private var hide: Task<Void, Never>?

    @MainActor
    func show(_ text: String, systemImage: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            message = Message(text: text, systemImage: systemImage)
        }
        hide?.cancel()
        hide = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { message = nil }
        }
    }
}

struct QueueToast: View {
    @ObservedObject private var feedback = QueueFeedback.shared

    var body: some View {
        VStack {
            if let message = feedback.message {
                Label(message.text, systemImage: message.systemImage)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(message.id)
                    .accessibilityAddTraits(.isStaticText)
            }
            Spacer()
        }
        .padding(.top, 8)
        .allowsHitTesting(false)
        .sensoryFeedback(.success, trigger: feedback.message?.id)
    }
}

// MARK: - Actions

extension JellyfinViewModel {
    func playNext(_ tracks: [AudioItem]) {
        guard !tracks.isEmpty else { return }
        playerManager.playNext(tracks)
        QueueFeedback.shared.show(tracks.count == 1 ? "Riprodotto dopo" : "\(tracks.count) brani riprodotti dopo",
                                  systemImage: "text.line.first.and.arrowtriangle.forward")
    }

    func addToQueue(_ tracks: [AudioItem]) {
        guard !tracks.isEmpty else { return }
        playerManager.addToQueue(tracks)
        QueueFeedback.shared.show(tracks.count == 1 ? "Aggiunto alla coda" : "\(tracks.count) brani in coda",
                                  systemImage: "text.line.last.and.arrowtriangle.forward")
    }

    /// The album's songs in order, loaded without touching the open album page.
    func tracks(ofAlbum album: AlbumItem) async -> [AudioItem] {
        await fetchAlbumTracksDirectly(albumId: album.id)
    }
}

// MARK: - Menu items

/// The two queue entries for a context or "⋯" menu, for songs already at hand.
struct QueueMenuItems: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let tracks: [AudioItem]

    var body: some View {
        Button {
            viewModel.playNext(tracks)
        } label: {
            Label("Riproduci dopo", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            viewModel.addToQueue(tracks)
        } label: {
            Label("Aggiungi alla coda", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
    }
}

/// The same for an album whose songs haven't been loaded yet.
struct AlbumQueueMenuItems: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let album: AlbumItem

    var body: some View {
        Button {
            Task { viewModel.playNext(await viewModel.tracks(ofAlbum: album)) }
        } label: {
            Label("Riproduci dopo", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            Task { viewModel.addToQueue(await viewModel.tracks(ofAlbum: album)) }
        } label: {
            Label("Aggiungi alla coda", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
    }
}

extension View {
    /// Apple Music's swipes on a song row in a List: right for "Riproduci dopo",
    /// left for "Aggiungi alla coda".
    func queueSwipeActions(_ track: AudioItem, viewModel: JellyfinViewModel) -> some View {
        self
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    viewModel.playNext([track])
                } label: {
                    Label("Dopo", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                .tint(.purple)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button {
                    viewModel.addToQueue([track])
                } label: {
                    Label("In coda", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                .tint(.orange)
            }
    }
}

// MARK: - Play / Shuffle

/// Apple Music's two buttons above a song list: play from the top, or shuffle.
struct LibraryPlayButtons: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let tracks: [AudioItem]

    var body: some View {
        HStack(spacing: 12) {
            button("Riproduci", systemImage: "play.fill") {
                if let first = tracks.first { viewModel.playerManager.play(item: first, in: tracks) }
            }
            button("Casuale", systemImage: "shuffle") {
                viewModel.playerManager.playAlbumShuffled(tracks: tracks)
            }
        }
        .disabled(tracks.isEmpty)
    }

    private func button(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
