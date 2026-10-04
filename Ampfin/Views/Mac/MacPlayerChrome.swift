// MacPlayerChrome.swift
// What every Mac page carries: the floating playback bar at the bottom, a toolbar with no
// background (so the page color reaches the top of the window, also in full screen), and
// the scroll tracking that shrinks the bar while reading down a page, as the iPhone's
// tab bar accessory does.

#if os(macOS)
import SwiftUI

/// Shared by the window and its pages: the side panel, the bar's size, the full player.
@Observable
final class MacPlayerState {
    var showPanel = false
    var panelTab = MacSidePanel.Tab.queue.rawValue
    /// The bar shrinks to cover and play button while scrolling down a page.
    var minimized = false
    /// The whole-window Now Playing view.
    var showFullPlayer = false
}

private struct MacPageChrome: ViewModifier {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Environment(MacPlayerState.self) private var state

    func body(content: Content) -> some View {
        content
            // Pages scroll under the bar, with room to see their last row.
            .contentMargins(.bottom, 96, for: .scrollContent)
            .overlay(alignment: .bottom) {
                MacPlaybackBar(player: viewModel.playerManager)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
            }
            .toolbar(removing: .title)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            // With Now Playing open, Back and the sidebar button would sit on top of it.
            .toolbarVisibility(state.showFullPlayer ? .hidden : .automatic, for: .windowToolbar)
    }
}

private struct MacScrollTracking: ViewModifier {
    @Environment(MacPlayerState.self) private var state

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { old, new in
                let delta = new - old
                if new < 40 {
                    if state.minimized { state.minimized = false }
                } else if delta > 4 {
                    if !state.minimized { state.minimized = true }
                } else if delta < -4 {
                    if state.minimized { state.minimized = false }
                }
            }
    }
}

extension View {
    /// The playback bar and the clear toolbar; put on every page of the Mac window.
    func macPageChrome() -> some View { modifier(MacPageChrome()) }

    /// Shrinks the playback bar while this scroll view goes down, grows it going up.
    func macScrollTracking() -> some View { modifier(MacScrollTracking()) }
}
#endif
