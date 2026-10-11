// PlayerPresentation.swift
// Whether the full player is open, and the layer that shows it. This used to be a @State of
// ContentView: every open/close re-ran the body of the whole tab hierarchy, including the
// visible list, in the very frames of the slide.

import SwiftUI
import Observation

@Observable
final class PlayerPresentation {
    static let shared = PlayerPresentation()

    var isExpanded = false
    /// The close drag. Owned here, not by the view: a close leaves its offset in place for
    /// the slide-out, and if the user reopens before the removal ends, SwiftUI re-inserts the
    /// same view with that offset still set.
    let drag = PlayerDrag()
    /// True while the full player covers the screen, and a moment after it starts closing.
    /// The animated backgrounds underneath stop drawing meanwhile, so they don't compete
    /// with the slide for the GPU.
    private(set) var isCovering = false
    private var uncoverTask: Task<Void, Never>?

    private init() {}

    /// Opens the full player. The drag offset is cleared first, without animation, so the
    /// player comes up in place even when a close is still removing the old view.
    @MainActor
    func open() {
        resetDragOffset()
        withAnimation(.spring(response: 0.5, dampingFraction: 0.88)) {
            isExpanded = true
        }
    }

    @MainActor
    private func resetDragOffset() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { drag.offset = 0 }
    }

    /// Follows `isExpanded`; called by the layer when it changes.
    @MainActor
    func expandedChanged(_ expanded: Bool) {
        uncoverTask?.cancel()
        if expanded {
            // Second reset, for opens that don't go through open().
            resetDragOffset()
            isCovering = true
        } else {
            // Resume only once the slide is over.
            uncoverTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                isCovering = false
            }
        }
    }
}

#if os(iOS)
/// The full player above the tabs, with its slide in and out.
struct FullPlayerLayer: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Bindable private var presentation = PlayerPresentation.shared

    var body: some View {
        ZStack {
            if let playingItem = viewModel.currentlyPlayingItem, presentation.isExpanded {
                // Full player: its own Liquid Glass elements materialize in place
                // (no shape-morph from the mini bar; see NowPlayingFullView doc comment).
                NowPlayingFullView(
                    item: playingItem,
                    isPlaying: viewModel.isPlaying,
                    clock: viewModel.clock,
                    duration: playingItem.duration ?? 0,
                    artworkURL: viewModel.artworkURL(for: playingItem.AlbumId ?? playingItem.id, size: 600),
                    onPlayPause: { viewModel.playerManager.togglePlayPause() },
                    onBackward: { viewModel.playerManager.backward() },
                    onForward: { viewModel.playerManager.forward() },
                    onSeek: { time in viewModel.playerManager.seek(to: time) },
                    isExpanded: $presentation.isExpanded
                )
                // Slides as one sheet; materializing its glass pieces on top
                // of the slide flickered at the end.
                .glassEffectTransition(.identity)
                // Rises from the accessory like a sheet.
                .transition(.move(edge: .bottom))
                // Stays above the tabs while it slides out, instead of dropping behind
                // them for the last frames of the removal.
                .zIndex(1)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.88), value: presentation.isExpanded)
        .onChange(of: presentation.isExpanded) { _, expanded in
            presentation.expandedChanged(expanded)
        }
    }
}
#endif
