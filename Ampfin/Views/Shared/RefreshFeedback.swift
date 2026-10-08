// RefreshFeedback.swift
// Visible feedback for the pull to refresh of the Home and the library tabs. The system
// spinner can end up behind the navigation bar (or Ampfin's own top bar), so a glass
// capsule under the bar says "updating" and then "updated", with a haptic at each end.
// Only user-initiated pulls go through `run`; the automatic sync stays silent.

import SwiftUI
#if os(iOS)
import UIKit
#endif

@MainActor
final class LibraryRefresh: ObservableObject {
    static let shared = LibraryRefresh()

    enum Phase: Equatable {
        case idle
        case refreshing
        case done(Date)
    }

    @Published private(set) var phase: Phase = .idle
    /// Lets a late "back to idle" timer see that a newer refresh has started.
    private var generation = 0

    private init() {}

    /// Runs the refresh work with the banner. A second pull during a refresh just waits
    /// for the first one instead of starting another.
    func run(_ work: () async -> Void) async {
        if phase == .refreshing {
            while phase == .refreshing { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        generation += 1
        phase = .refreshing
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
        await work()
        phase = .done(Date())
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
        let mine = generation
        // Not awaited here: the system spinner must close as soon as the work is done.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.generation == mine, self.phase != .refreshing else { return }
            self.phase = .idle
        }
    }

    /// Returns once no refresh is running and the pull-down spring-back has had time to
    /// finish. Screens call it before swapping content that the refresh made stale: a
    /// layout change while the scroll view is rubber-banding cancels its spring.
    func settled() async {
        while phase == .refreshing { try? await Task.sleep(for: .milliseconds(100)) }
        if case .done(let date) = phase {
            let wait = 0.8 - Date().timeIntervalSince(date)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        }
    }
}

private struct LibraryRefreshBanner: ViewModifier {
    @ObservedObject private var refresh = LibraryRefresh.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                // The animation sits on the overlay only, so the list underneath isn't touched.
                Group {
                    if refresh.phase != .idle {
                        pill
                            .padding(.top, 8)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? .easeInOut(duration: 0.2) : (refresh.phase == .refreshing ? .springy(0.5) : .soft(0.45)),
                           value: refresh.phase)
                .allowsHitTesting(false)
            }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            if refresh.phase == .refreshing {
                ProgressView()
                Text("Aggiorno la libreria…")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Libreria aggiornata")
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// The "Aggiorno la libreria…" capsule at the top of a pull-to-refresh screen.
    func libraryRefreshBanner() -> some View {
        modifier(LibraryRefreshBanner())
    }
}
