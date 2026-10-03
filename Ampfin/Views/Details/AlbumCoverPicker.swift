// AlbumCoverPicker.swift
// Album page → "Cambia copertina": the server's suggestions, iTunes and Deezer, or a photo.
// The change is made on the server, so every client sees it.

import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

struct AlbumCoverPicker: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @Environment(\.dismiss) private var dismiss
    let album: AlbumItem

    @State private var canEdit: Bool?
    @State private var serverCovers: [CoverCandidate] = []
    @State private var storeCovers: [CoverCandidate] = []
    @State private var loadingServer = true
    @State private var searching = false
    @State private var query = ""
    @State private var pending: CoverCandidate?
    @State private var photoItem: PhotosPickerItem?
    @State private var saving = false
    @State private var errorText: String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if canEdit == false {
                    ContentUnavailableView("Solo per amministratori",
                                           systemImage: "lock",
                                           description: Text("Jellyfin lascia cambiare le copertine solo agli utenti amministratori."))
                } else {
                    content
                }
            }
            .navigationTitle("Copertina")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                }
                if canEdit == true {
                    ToolbarItem(placement: .primaryAction) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Da Foto", systemImage: "photo.on.rectangle")
                        }
                    }
                }
            }
            .overlay {
                if saving {
                    ProgressView("Salvo sul server…")
                        .padding(20)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
            }
            .disabled(saving)
        }
        .task { await start() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .confirmationDialog("Usare questa copertina?", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }
        ), titleVisibility: .visible, presenting: pending) { candidate in
            Button("Usa questa copertina") { Task { await apply(candidate) } }
            Button("Annulla", role: .cancel) {}
        } message: { candidate in
            Text([candidate.source, candidate.sizeLabel, candidate.title].compactMap { $0 }.joined(separator: " · "))
        }
        .alert("Copertina non cambiata", isPresented: Binding(
            get: { errorText != nil }, set: { if !$0 { errorText = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorText ?? "")
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                section("Dal server", loading: loadingServer, covers: serverCovers,
                        empty: "Nessuna proposta dai provider di Jellyfin.")

                section("iTunes e Deezer", loading: searching, covers: storeCovers,
                        empty: query.isEmpty ? "Cerca un album qui sopra." : "Nessun risultato per \"\(query)\".")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .searchable(text: $query, prompt: "Artista e album")
        .onSubmit(of: .search) { Task { await search() } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            CachedAsyncImage(url: viewModel.artworkURL(for: album.id, size: 400), targetSize: 96,
                content: { $0.resizable().aspectRatio(contentMode: .fill) },
                placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
            )
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(album.Name)
                    .font(.headline)
                    .lineLimit(2)
                if let artist = album.AlbumArtist {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text("Tocca una copertina per usarla al posto di questa.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private func section(_ title: String, loading: Bool, covers: [CoverCandidate], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if covers.isEmpty {
                Text(empty)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(covers) { candidate in
                        Button { pending = candidate } label: { cell(candidate) }
                            .buttonStyle(.pressable)
                    }
                }
            }
        }
    }

    private func cell(_ candidate: CoverCandidate) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AsyncImage(url: candidate.thumbnail) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text([candidate.source, candidate.sizeLabel].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            if let title = candidate.title {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func start() async {
        query = Self.searchTerm(for: album)
        canEdit = await viewModel.canEditCovers()
        guard canEdit == true else { return }
        async let server = viewModel.remoteCovers(for: album.id)
        await search()
        // Biggest first: what the server lists first is not always the best.
        serverCovers = await server.sorted { ($0.width ?? 0) > ($1.width ?? 0) }
        loadingServer = false
    }

    private func search() async {
        searching = true
        storeCovers = await CoverSearch.search(query)
        searching = false
    }

    private func apply(_ candidate: CoverCandidate) async {
        saving = true
        defer { saving = false }
        do {
            try await viewModel.setCover(for: album.id, to: candidate)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        saving = true
        defer { saving = false; photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let jpeg = Self.jpeg(from: data, maxPixels: 1500) else {
                errorText = "Non riesco a leggere la foto."
                return
            }
            try await viewModel.uploadCover(for: album.id, jpegData: jpeg)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// "Artist Album" without the "(Deluxe Edition)", "[EP]"… that confuse store searches.
    static func searchTerm(for album: AlbumItem) -> String {
        let name = album.Name
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return [album.AlbumArtist, name.isEmpty ? album.Name : name]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// Any photo (HEIC, PNG…) as a JPEG of at most `maxPixels` on the long side.
    static func jpeg(from data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
