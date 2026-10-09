// QueueActions.swift
// "Riproduci dopo" and "Aggiungi alla coda", as in Apple Music: menu items for songs
// and albums, list swipe actions, and the little confirmation that drops in at the top.

import SwiftUI
#if os(iOS)
import UIKit
#endif

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

// MARK: - Swipe outside a List

/// The same two swipes for rows that aren't in a List (the hero pages), where
/// `.swipeActions` doesn't exist: right for "Dopo", left for "In coda". Past the
/// threshold the action is armed (a tick); letting go there commits and the row springs
/// back. The offset is @State of this modifier, so only this row redraws while dragging.
private struct QueueDragSwipe: ViewModifier {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let track: AudioItem
    /// The page color, to hide the action color behind the row while it is still.
    let background: Color

    @State private var dragX: CGFloat = 0

    private let threshold: CGFloat = 90

    /// The row's offset, with resistance past the threshold.
    private var offset: CGFloat {
        let distance = abs(dragX)
        let eased = distance <= threshold ? distance : threshold + (distance - threshold) * 0.3
        return dragX < 0 ? -eased : eased
    }

    func body(content: Content) -> some View {
        let x = offset
        let armed = abs(dragX) >= threshold
        content
            .background(x == 0 ? Color.clear : background)
            .offset(x: x)
            .background { if x != 0 { action(for: x, armed: armed) } }
            .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.8), value: x)
            .sensoryFeedback(.impact(weight: .light), trigger: armed) { _, isArmed in isArmed }
            #if os(iOS)
            .gesture(HorizontalPan { phase, translation in
                switch phase {
                case .changed:
                    dragX = translation
                case .ended:
                    if abs(translation) >= threshold {
                        if translation > 0 { viewModel.playNext([track]) } else { viewModel.addToQueue([track]) }
                    }
                    dragX = 0
                default:
                    dragX = 0
                }
            })
            #endif
    }

    private func action(for x: CGFloat, armed: Bool) -> some View {
        let next = x > 0
        return Rectangle()
            .fill(next ? Color.purple : Color.orange)
            .overlay(alignment: next ? .leading : .trailing) {
                VStack(spacing: 2) {
                    Image(systemName: next ? "text.line.first.and.arrowtriangle.forward" : "text.line.last.and.arrowtriangle.forward")
                        .font(.title3)
                        .scaleEffect(armed ? 1.15 : 1)
                    Text(next ? "Dopo" : "In coda")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: abs(x))
                .opacity(min(1, abs(x) / 50))
                .animation(.snappy(duration: 0.2), value: armed)
            }
            .clipped()
            .accessibilityHidden(true)
    }
}

#if os(iOS)
/// A UIKit pan that only begins on a clearly horizontal movement. A SwiftUI DragGesture
/// inside a ScrollView can swallow the scroll view's pan (iOS 18+); here a vertical pan
/// fails at once, so the ScrollView always wins for vertical scrolling.
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    /// Called with the phase and the horizontal translation since the pan began.
    let onChange: (UIGestureRecognizer.State, CGFloat) -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 2
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        onChange(recognizer.state, recognizer.translation(in: recognizer.view).x)
    }
}
#endif

extension View {
    /// Swipe right for "Dopo", left for "In coda" on a row outside a List.
    func queueDragSwipe(_ track: AudioItem, background: Color) -> some View {
        modifier(QueueDragSwipe(track: track, background: background))
    }
}

// MARK: - Play / Shuffle

/// Apple Music's two buttons above a song list: play from the top, or shuffle. An
/// optional third, square button sits in the same row (sort, download all).
struct LibraryPlayButtons<Accessory: View>: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    let tracks: [AudioItem]
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                button("Riproduci", systemImage: "play.fill") {
                    if let first = tracks.first { viewModel.playerManager.play(item: first, in: tracks) }
                }
                .disabled(tracks.isEmpty)
                button("Casuale", systemImage: "shuffle") {
                    viewModel.playerManager.playAlbumShuffled(tracks: tracks)
                }
                .disabled(tracks.isEmpty)
                accessory()
            }
        }
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

extension LibraryPlayButtons where Accessory == EmptyView {
    init(tracks: [AudioItem]) {
        self.init(tracks: tracks) { EmptyView() }
    }
}

/// The square glass button that completes the row of LibraryPlayButtons.
struct LibraryRowIcon<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(.body.weight(.semibold))
            .foregroundStyle(.tint)
            .frame(width: 48, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
