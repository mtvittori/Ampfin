import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject var colorManager = AccentColorManager.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var downloadSize: Int64 = 0
    @State private var cacheSize: Int64 = 0
    @State private var libraryCacheSize: Int64 = 0
    @State private var songCacheSize: Int64 = 0
    @ObservedObject private var backup = SettingsBackup.shared
    @AppStorage(TopBarStyle.storageKey) private var topBarStyle = TopBarStyle.system.rawValue
    @State private var exportFile: SettingsBackupFile?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var confirmRestore = false

    // Preset colors
    private let presetColors: [(String, Color)] = [
        ("Blu", .blue),
        ("Viola", .purple),
        ("Rosa", .pink),
        ("Rosso", .red),
        ("Arancione", .orange),
        ("Giallo", .yellow),
        ("Verde", .green),
        ("Menta", .mint),
        ("Ciano", .cyan),
        ("Indaco", .indigo),
    ]

    var body: some View {
        List {
            // MARK: - Accent Color
            Section {
                Toggle(isOn: $colorManager.followsArtwork.animation()) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(colorManager.artworkAccent.map { AnyShapeStyle($0) }
                                  ?? AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .red], center: .center)))
                            .frame(width: 28, height: 28)
                        Text("Colore dell'album in ascolto")
                    }
                }

                // Preset grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 12) {
                    ForEach(presetColors, id: \.0) { name, color in
                        Button {
                            colorManager.followsArtwork = false
                            colorManager.hasCustomColor = true
                            colorManager.accentColor = color
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(width: 36, height: 36)
                                .overlay {
                                    if !colorManager.followsArtwork && colorManager.hasCustomColor && colorManager.accentColor.description == color.description {
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                    }
                }
                .padding(.vertical, 8)
                .opacity(colorManager.followsArtwork ? 0.4 : 1)

                // Custom color picker
                ColorPicker("Colore personalizzato", selection: $colorManager.accentColor, supportsOpacity: false)
                    .onChange(of: colorManager.accentColor) {
                        colorManager.hasCustomColor = true
                        colorManager.followsArtwork = false
                    }

                // Reset
                if colorManager.hasCustomColor || colorManager.followsArtwork {
                    Button("Ripristina colore predefinito", role: .destructive) {
                        colorManager.resetToDefault()
                    }
                }
            } header: {
                Text("Colore Accent")
            } footer: {
                Text("Scegli il colore principale dell'interfaccia dell'app. Con \"Colore dell'album in ascolto\" l'app prende il colore più vivo della copertina che sta suonando e cambia a ogni album.")
            }

            // MARK: - Liquid Glass Tint
            Section {
                Toggle("Tinta Liquid Glass", isOn: $colorManager.glassTintEnabled)

                if colorManager.glassTintEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Intensità colore")
                            Spacer()
                            Text("\(Int(colorManager.glassTintIntensity * 100))%")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $colorManager.glassTintIntensity, in: 0...1)
                    }
                }
            } header: {
                Text("Liquid Glass")
            } footer: {
                Text("Quando attivo, il vetro di card e barra di riproduzione viene tinto con il colore dominante della copertina. Disattiva per il vetro predefinito. Usa lo slider per regolare quanto marcata sia la tinta.")
            }

            // MARK: - Home
            Section {
                Picker("Barra in alto", selection: $topBarStyle) {
                    ForEach(TopBarStyle.allCases) { style in
                        Text(style.label).tag(style.rawValue)
                    }
                }
            } header: {
                Text("Barra in alto")
            } footer: {
                Text("Barra Ampfin: titolo grande e pulsanti più grandi in una barra propria, al posto di quella di sistema.")
            }

            // MARK: - Now Playing Background
            Section {
                Toggle("Sfondo sfocato", isOn: $colorManager.nowPlayingBlurredBackground)
            } header: {
                Text("Schermata Play")
            } footer: {
                Text("Lo sfondo della copertina nella schermata Play, sfocata o nitida.")
            }

            // MARK: - Audio output
            AudioOutputSection()

            // MARK: - Equalizer
            Section {
                EqualizerView()
            } header: {
                Text("Equalizzatore")
            } footer: {
                Text("Regola le frequenze audio per personalizzare il suono. Scegli un preset o regola manualmente ogni banda.")
            }

            // MARK: - Streaming Quality
            Section {
                Picker("Wi-Fi", selection: $viewModel.streamQualityWifi) {
                    ForEach(JellyfinViewModel.StreamQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }

                #if os(iOS)
                Picker("Rete cellulare", selection: $viewModel.streamQualityCellular) {
                    ForEach(JellyfinViewModel.StreamQuality.allCases) { quality in
                        Text(quality.label).tag(quality)
                    }
                }
                #endif
            } header: {
                Text("Qualità streaming")
            } footer: {
                Text("Seleziona la qualità di riproduzione. \"Originale\" trasmette senza conversione.")
            }

            // MARK: - Audio Output Info
            if viewModel.currentlyPlayingItem != nil {
                Section {
                    let pm = viewModel.playerManager!

                    HStack {
                        Text("Formato")
                        Spacer()
                        Text(pm.currentCodec.isEmpty ? "–" : pm.currentCodec)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Text(formatBitrate(pm.currentBitrate))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Frequenza di campionamento")
                        Spacer()
                        Text(formatSampleRate(pm.currentSampleRate))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Modalità")
                        Spacer()
                        Text(pm.isDirectStream ? "Direct Stream" : "Transcodifica")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Sorgente audio")
                } footer: {
                    Text("Informazioni sul file audio in riproduzione.")
                }

                Section {
                    let pm = viewModel.playerManager!

                    HStack {
                        Text("Dispositivo")
                        Spacer()
                        Text(pm.currentOutputDevice.isEmpty ? "–" : pm.currentOutputDevice)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Frequenza hardware")
                        Spacer()
                        Text(formatSampleRate(pm.deviceSampleRate))
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Canali uscita")
                        Spacer()
                        Text(pm.deviceOutputChannels > 0 ? "\(pm.deviceOutputChannels)" : "–")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Latenza uscita")
                        Spacer()
                        Text(pm.deviceOutputLatency > 0 ? String(format: "%.1f ms", pm.deviceOutputLatency * 1000) : "–")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Uscita dispositivo")
                } footer: {
                    Text("Valori reali rilevati dall'hardware audio del dispositivo.")
                }
            }

            // MARK: - Account
            Section {
                if !viewModel.serverUrl.isEmpty {
                    HStack {
                        Text("Server")
                        Spacer()
                        Text(viewModel.serverUrl)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Button("Logout", role: .destructive) {
                    viewModel.logout()
                }
            } header: {
                Text("Account")
            }

            // MARK: - Downloads
            Section {
                HStack {
                    Label("Download offline", systemImage: "arrow.down.circle.fill")
                    Spacer()
                    Text(formatBytes(downloadSize))
                        .foregroundColor(.secondary)
                }

                if downloadManager.downloadStates.values.contains(where: {
                    if case .downloaded = $0 { return true }; return false
                }) {
                    Button("Elimina tutti i download", role: .destructive) {
                        downloadManager.removeAllDownloads()
                        refreshSizes()
                    }
                }
            } header: {
                Text("Download")
            } footer: {
                Text("I brani scaricati vengono salvati sul dispositivo per l'ascolto offline.")
            }

            // MARK: - Cache
            Section {
                HStack {
                    Label("Cache immagini", systemImage: "photo.stack")
                    Spacer()
                    Text(formatBytes(cacheSize))
                        .foregroundColor(.secondary)
                }

                Button("Svuota cache immagini", role: .destructive) {
                    ImageCacheService.shared.clearAll()
                    refreshSizes()
                }

                HStack {
                    Label("Cache brani", systemImage: "music.note.list")
                    Spacer()
                    Text(formatBytes(songCacheSize))
                        .foregroundColor(.secondary)
                }

                Button("Svuota cache brani", role: .destructive) {
                    AudioStreamCache.shared.clear()
                    Task {
                        try? await Task.sleep(for: .milliseconds(300))
                        refreshSizes()
                    }
                }
            } header: {
                Text("Cache")
            } footer: {
                Text("La cache immagini viene ricreata automaticamente durante l'uso. La cache brani tiene gli ultimi brani ascoltati (fino a 2 GB) e scarica in anticipo il prossimo della coda, così partono subito.")
            }

            // MARK: - Backup
            Section {
                HStack {
                    Label("Backup su Jellyfin", systemImage: "externaldrive.badge.icloud")
                    Spacer()
                    if backup.isWorking {
                        ProgressView()
                    } else if let date = backup.lastServerBackup {
                        Text(date, style: .relative)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Mai")
                            .foregroundColor(.secondary)
                    }
                }

                Button("Fai il backup ora", systemImage: "arrow.up.circle") {
                    Task { await backup.backupNow() }
                }
                .disabled(backup.isWorking)

                Button("Ripristina da Jellyfin", systemImage: "arrow.down.circle") {
                    confirmRestore = true
                }
                .disabled(backup.isWorking)

                Button("Esporta su file…", systemImage: "square.and.arrow.up") {
                    exportFile = backup.exportFile()
                    showExporter = true
                }

                Button("Importa da file…", systemImage: "square.and.arrow.down") {
                    showImporter = true
                }

                if let message = backup.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Backup impostazioni")
            } footer: {
                Text("Aspetto, preferiti, qualità, equalizzatore e artisti uniti vengono salvati da soli sul tuo server Jellyfin e tornano da soli se reinstalli l'app. iCloud automatico richiede un account sviluppatore a pagamento: per avere una copia su iCloud, esporta il file e salvalo in iCloud Drive.")
            }
            .confirmationDialog("Sostituire le impostazioni con quelle del backup su Jellyfin?",
                                isPresented: $confirmRestore, titleVisibility: .visible) {
                Button("Ripristina", role: .destructive) {
                    Task { await backup.restoreFromServer() }
                }
            }
            .fileExporter(isPresented: $showExporter, document: exportFile, contentType: .json,
                          defaultFilename: exportFile?.suggestedName) { result in
                if case .success = result { backup.message = "Backup esportato." }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
                if case .success(let url) = result { backup.importFile(at: url) }
            }

            // MARK: - Artists
            Section {
                NavigationLink {
                    ArtistMergeSettingsView()
                        .environmentObject(viewModel)
                } label: {
                    Label("Unisci artisti", systemImage: "arrow.triangle.merge")
                }
            } header: {
                Text("Artisti")
            } footer: {
                Text("Doppioni e featuring diventano un solo artista, in automatico o a mano.")
            }

            // MARK: - Library Sync
            Section {
                Picker("Aggiornamento automatico", selection: $viewModel.libraryRefreshInterval) {
                    ForEach(JellyfinViewModel.LibraryRefreshInterval.allCases) { interval in
                        Text(interval.label).tag(interval)
                    }
                }

                HStack {
                    Text("Ultimo aggiornamento")
                    Spacer()
                    if let lastSync = viewModel.lastLibrarySyncDate {
                        Text("\(lastSync, style: .relative) fa")
                            .foregroundColor(.secondary)
                    } else {
                        Text("Mai")
                            .foregroundColor(.secondary)
                    }
                }

                HStack {
                    Label("Cache libreria", systemImage: "music.note.house")
                    Spacer()
                    Text(formatBytes(libraryCacheSize))
                        .foregroundColor(.secondary)
                }

                Button {
                    Task {
                        await viewModel.fetchAllLibraryData()
                        refreshSizes()
                    }
                } label: {
                    HStack {
                        Label("Aggiorna libreria ora", systemImage: "arrow.clockwise")
                        Spacer()
                        if viewModel.isLoading {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isLoading)

                Button("Svuota cache libreria", role: .destructive) {
                    viewModel.clearLibraryCache()
                    refreshSizes()
                }
            } header: {
                Text("Sincronizzazione Libreria")
            } footer: {
                Text("Scegli ogni quanto aggiornare automaticamente la libreria dal server. Con \"Solo manuale\" la libreria viene aggiornata solo premendo il pulsante.")
            }

            // MARK: - About
            Section {
                HStack {
                    Text("Versione")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Info")
            }
        }
        .navigationTitle("Impostazioni")
        .onAppear {
            refreshSizes()
            viewModel.playerManager?.refreshAudioOutputInfo()
        }
    }

    private func refreshSizes() {
        downloadSize = downloadManager.totalDownloadSize()
        cacheSize = ImageCacheService.shared.diskSize()
        libraryCacheSize = LibraryCacheService.shared.diskSize()
        songCacheSize = AudioStreamCache.shared.size()
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatBitrate(_ kbps: Double) -> String {
        if kbps <= 0 { return "–" }
        if kbps >= 1000 {
            return String(format: "%.1f Mbps", kbps / 1000.0)
        }
        return "\(Int(kbps)) kbps"
    }

    private func formatSampleRate(_ hz: Double) -> String {
        if hz <= 0 { return "–" }
        let kHz = hz / 1000.0
        if kHz == kHz.rounded() {
            return "\(Int(kHz)) kHz"
        }
        return String(format: "%.1f kHz", kHz)
    }
}
