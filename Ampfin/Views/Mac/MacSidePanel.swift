// MacSidePanel.swift
// The panel on the right: what is playing and what is coming up, or the song's lyrics.

#if os(macOS)
import SwiftUI

struct MacSidePanel: View {
    enum Tab: String { case queue, lyrics }
    @Binding var tab: String

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Coda").tag(Tab.queue.rawValue)
                Text("Testi").tag(Tab.lyrics.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            if tab == Tab.lyrics.rawValue {
                MacLyricsPanel()
            } else {
                MacQueuePanel()
            }
        }
    }
}

// MARK: - Queue

struct MacQueuePanel: View {
    @EnvironmentObject var viewModel: JellyfinViewModel

    /// The list watches the player itself, so it follows the queue as it changes.
    var body: some View {
        Content(player: viewModel.playerManager)
    }

    private struct Content: View {
        @EnvironmentObject var viewModel: JellyfinViewModel
        @ObservedObject var player: AudioPlayerManager

        var body: some View {
            if let current = player.currentlyPlayingItem {
                List {
                    SwiftUI.Section("In riproduzione") {
                        row(current, isCurrent: true)
                    }
                    SwiftUI.Section {
                        ForEach(player.upNext) { item in
                            row(item, isCurrent: false)
                        }
                    } header: {
                        HStack {
                            Text("A seguire")
                            Spacer()
                            Toggle(isOn: $player.autoplayEnabled) {
                                Image(systemName: "infinity")
                            }
                            .toggleStyle(.button)
                            .controlSize(.small)
                            .help("Riproduzione automatica")
                        }
                    }
                }
                .listStyle(.sidebar)
            } else {
                ContentUnavailableView("Niente in riproduzione", systemImage: "music.note",
                                       description: Text("Scegli un brano per vedere la coda."))
            }
        }

        private func row(_ item: AudioItem, isCurrent: Bool) -> some View {
            HStack(spacing: 10) {
                MacCover(itemId: item.AlbumId ?? item.id, size: 36, radius: 4, imageSize: 100)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.Name).lineLimit(1)
                        .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    Text(viewModel.artistName(for: item) ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(MacFormat.clock(item.duration ?? 0)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !isCurrent else { return }
                viewModel.playerManager.play(item: item, in: viewModel.playerManager.queue)
            }
            .contextMenu {
                if !isCurrent {
                    Button { viewModel.playerManager.play(item: item, in: viewModel.playerManager.queue) } label: {
                        Label("Riproduci ora", systemImage: "play.fill")
                    }
                    Button(role: .destructive) { viewModel.playerManager.removeFromQueue(item) } label: {
                        Label("Rimuovi dalla coda", systemImage: "minus.circle")
                    }
                }
            }
        }
    }
}

// MARK: - Lyrics

struct MacLyricsPanel: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var lines: [JellyfinAPIService.LyricLine] = []
    @State private var loading = false

    var body: some View {
        Group {
            if viewModel.currentlyPlayingItem == nil {
                ContentUnavailableView("Niente in riproduzione", systemImage: "music.note")
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView("Nessun testo", systemImage: "text.quote",
                                       description: Text("Il server non ha i testi di questo brano."))
            } else {
                ClockReader(clock: viewModel.clock) { time in
                    let active = lines.last { ($0.start ?? .infinity) <= time }?.id
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(lines) { line in
                                    Text(line.text.isEmpty ? " " : line.text)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(line.start == nil || line.id == active ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(line.id)
                                        .onTapGesture {
                                            if let start = line.start { viewModel.playerManager.seek(to: start) }
                                        }
                                }
                            }
                            .padding(20)
                        }
                        .onChange(of: active) { _, id in
                            guard let id else { return }
                            withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }
        }
        .task(id: viewModel.currentlyPlayingItem?.id) {
            guard let item = viewModel.currentlyPlayingItem else { lines = []; return }
            loading = true
            lines = await viewModel.lyrics(for: item)
            loading = false
        }
    }
}
#endif
