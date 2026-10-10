import SwiftUI
import UniformTypeIdentifiers
import os

struct SettingsView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @ObservedObject var colorManager = AccentColorManager.shared
    private let downloadManager = DownloadManager.shared
    @State private var downloadSize: Int64 = 0
    @State private var cacheSize: Int64 = 0
    @State private var libraryCacheSize: Int64 = 0
    @State private var songCacheSize: Int64 = 0
    @ObservedObject private var backup = SettingsBackup.shared
    @State private var musicLibraries: [LibraryView] = []
    @State private var disabledLibraries: Set<String> = []
    @AppStorage(TopBarStyle.storageKey) private var topBarStyle = TopBarStyle.system.rawValue
    @AppStorage(AlbumBackdrop.storageKey) private var albumColorBackground = false
    @AppStorage(AlbumBackdropQuality.storageKey) private var albumBackdropQuality = AlbumBackdropQuality.initial
    @AppStorage(MixSource.storageKey) private var mixSource = MixSource.ampfin.rawValue
    @AppStorage(MixSource.topPicksKey) private var mixesInTopPicks = true
    @AppStorage(ScrobbleStatsStore.homeKey) private var showScrobbleStats = false
    @AppStorage(HomeSubtitleStyle.storageKey) private var homeSubtitleStyle = HomeSubtitleStyle.message.rawValue
    @AppStorage(LetterIndexStyle.storageKey) private var letterIndexStyle = LetterIndexStyle.classic.rawValue
    @AppStorage(CoverFlowSettings.storageKey) private var landscapeCoverFlow = false
    @AppStorage(CoverFlowSettings.resumeKey) private var coverFlowResumesPlaying = true
    @AppStorage(HeroCoverSettings.storageKey) private var heroCoverBelowIsland = false
    @AppStorage(JellyfinViewModel.hiResTo48kKey) private var hiResTo48k = true
    @AppStorage(HeartFlashSettings.storageKey) private var heartFlashOnly = false
    @AppStorage(PlayerModeButtonsSettings.storageKey) private var playerShowsModeButtons = false
    @State private var exportFile: SettingsBackupFile?
    @State private var showExporter = false
    @State private var showImporter = false
    @State private var confirmRestore = false
    #if os(iOS)
    @State private var currentIcon = UIApplication.shared.alternateIconName
    #endif

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
        #if os(macOS)
        // Mac settings idiom: toolbar tabs, one grouped form each, same grouping as the iOS pages.
        // Each tab has its own stack so the NavigationLinks inside the sections keep working.
        TabView {
            macTab("Account", icon: "person.crop.circle") {
                accountSection
            }
            macTab("Aspetto", icon: "swatchpalette") {
                accentSection
                glassSection
            }
            macTab("Audio", icon: "hifispeaker") {
                audioOutputSection
                equalizerSection
                streamingSection
                audioInfoSections
            }
            macTab("Libreria", icon: "music.note.square.stack") {
                musicLibrariesSection
                librarySyncSection
                artistsSection
                downloadsSection
                cacheSection
            }
            macTab("Backup", icon: "arrow.clockwise.icloud") {
                backupSection
            }
            macTab("Info", icon: "info.circle") {
                aboutSection
            }
        }
        .onAppear(perform: onPageAppear)
        #else
        // iOS: account and info inline, the rest in pages like the system Settings app.
        List {
            accountSection

            Section {
                pageLink("Aspetto", icon: "swatchpalette.fill", color: .pink) {
                    appIconSection
                    accentSection
                    glassSection
                    topBarSection
                    albumBackgroundSection
                    heroCoverSection
                    nowPlayingBackgroundSection
                    heartSection
                }
                pageLink("Home", icon: "house.fill", color: .orange) {
                    homeSubtitleSection
                    mixSection
                    statsSection
                }
                pageLink("Elenchi e Cover Flow", icon: "rectangle.stack.fill", color: .indigo) {
                    letterIndexSection
                    coverFlowSection
                }
                pageLink("Audio", icon: "hifispeaker.fill", color: .red, summary: viewModel.streamQualityWifi.label) {
                    audioOutputSection
                    equalizerSection
                    streamingSection
                    audioInfoSections
                }
                pageLink("Libreria", icon: "music.note.square.stack.fill", color: .blue) {
                    musicLibrariesSection
                    librarySyncSection
                    artistsSection
                    downloadsSection
                    cacheSection
                }
                pageLink("Backup", icon: "arrow.clockwise.icloud.fill", color: .green) {
                    backupSection
                }
            }

            aboutSection
        }
        .navigationTitle("Impostazioni")
        .onAppear(perform: onPageAppear)
        #endif
    }

    #if os(macOS)
    private func macTab<Content: View>(_ title: String, icon: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            Form { content() }
                .formStyle(.grouped)
                .navigationTitle(title)
        }
        .tabItem { Label(title, systemImage: icon) }
    }
    #endif

    #if os(iOS)
    /// A row of the main list that pushes a Form page. The pages are built here so they share this view's state.
    private func pageLink<Content: View>(_ title: String, icon: String, color: Color, summary: String? = nil,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationLink {
            Form { content() }
                .navigationTitle(title)
                .onAppear(perform: onPageAppear)
        } label: {
            HStack {
                Label {
                    Text(title)
                } icon: {
                    // Coloured gradient glyph on a soft tinted squircle, instead of a white one on a solid tile
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .symbolColorRenderingMode(.gradient)
                        .foregroundStyle(color)
                        .frame(width: 29, height: 29)
                        .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if let summary {
                    Spacer()
                    Text(summary)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    #endif

    private func onPageAppear() {
        refreshSizes()
        viewModel.playerManager?.refreshAudioOutputInfo()
        Task { await loadMusicLibraries() }
    }

    @ViewBuilder private var accentSection: some View {
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
    }

    @ViewBuilder private var glassSection: some View {
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
    }

    #if os(iOS)
    /// Alternate icons: nil name is the primary icon. Previews live in Assets.xcassets as IconPreview-*.
    private static let appIcons: [(name: String?, label: String, preview: String)] = [
        (nil, "Classica", "IconPreview-Classica"),
        ("AppIcon-Medusa", "Medusa", "IconPreview-Medusa"),
        ("AppIcon-Onda", "Onda", "IconPreview-Onda"),
        ("AppIcon-Vinile", "Vinile", "IconPreview-Vinile"),
        ("AppIcon-Cuffie", "Cuffie", "IconPreview-Cuffie"),
    ]

    @ViewBuilder private var appIconSection: some View {
        if UIApplication.shared.supportsAlternateIcons {
            Section {
                ForEach(Self.appIcons, id: \.label) { icon in
                    Button {
                        setAppIcon(icon.name)
                    } label: {
                        HStack(spacing: 14) {
                            Image(icon.preview)
                                .resizable()
                                .frame(width: 60, height: 60)
                                .clipShape(RoundedRectangle(cornerRadius: 60 * 0.22, style: .continuous))
                            Text(icon.label)
                                .foregroundStyle(.primary)
                            Spacer()
                            if currentIcon == icon.name {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Icona dell'app")
            }
        }
    }

    private func setAppIcon(_ name: String?) {
        guard name != currentIcon else { return }
        UIApplication.shared.setAlternateIconName(name) { error in
            if let error {
                Logger(subsystem: "Ampfin", category: "AppIcon").error("setAlternateIconName failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { currentIcon = UIApplication.shared.alternateIconName }
        }
    }

    @ViewBuilder private var topBarSection: some View {
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
    }

    @ViewBuilder private var albumBackgroundSection: some View {
        Section {
            Toggle("Sfondo dai colori dell'album", isOn: $albumColorBackground)
            if albumColorBackground {
                #if os(iOS)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Resa dello sfondo")
                    Slider(value: $albumBackdropQuality, in: 0...1, step: 0.1) {
                        Text("Resa dello sfondo")
                    } minimumValueLabel: {
                        Text("Leggera").font(.caption)
                    } maximumValueLabel: {
                        Text("Originale").font(.caption)
                    }
                    AlbumBackdropPreview(quality: albumBackdropQuality)
                    AlbumBackdropReadout(quality: albumBackdropQuality)
                }
                #endif
            }
        } header: {
            Text("Sfondo")
        } footer: {
            Text(albumColorBackground
                 ? "Lo sfondo delle schermate si tinge, sfumato, dei colori della copertina in ascolto. Più si sale verso «Originale», più la mesh si muove come nella versione originale, e più costa in batteria e fluidità."
                 : "Lo sfondo delle schermate si tinge, sfumato, dei colori della copertina in ascolto.")
        }
    }

    @ViewBuilder private var heroCoverSection: some View {
        Section {
            Toggle("Copertina sotto la Dynamic Island", isOn: $heroCoverBelowIsland)
        } header: {
            Text("Copertina")
        } footer: {
            Text("Sposta in basso la copertina delle pagine album e artista quanto basta per non finire sotto la Dynamic Island; lo spazio sopra prende il colore della copertina.")
        }
    }

    @ViewBuilder private var homeSubtitleSection: some View {
        Section {
            Picker("Sottotitolo della Home", selection: $homeSubtitleStyle) {
                ForEach(HomeSubtitleStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
        } footer: {
            Text("Messaggio per te: una frase sulla tua musica (un anniversario, le novità da ascoltare, i tuoi ascolti della settimana…), che cambia durante la giornata. Con la barra Ampfin, toccala per leggerne un'altra.")
        }
    }

    @ViewBuilder private var mixSection: some View {
        Section {
            Picker("Mix consigliati", selection: $mixSource) {
                ForEach(MixSource.allCases) { source in
                    Text(source.label).tag(source.rawValue)
                }
            }
            Toggle("Mix in Scelti per te", isOn: $mixesInTopPicks)
                .disabled(mixSource != MixSource.ampfin.rawValue)
        } header: {
            Text("Mix in Home")
        } footer: {
            Text("Ampfin: mix fatti ogni giorno dall'app in base a ciò che ascolta il tuo utente (ognuno ha i suoi). Jellyfin: le playlist generate dai plugin del server (AudioMuse-AI, Playlist Generator). Mix in Scelti per te: il Mix del giorno e Novità per te anche come schede grandi tra gli album, come in Apple Music.")
        }
    }

    @ViewBuilder private var statsSection: some View {
        Section {
            Toggle("Statistiche d'ascolto in Home", isOn: $showScrobbleStats)
            NavigationLink {
                ScrobbleStatsPage()
            } label: {
                Label("Statistiche d'ascolto", systemImage: "chart.bar.xaxis")
            }
        } footer: {
            Text("Ascolti, artisti, album e brani più ascoltati, in stile last.fm.")
        }
    }

    @ViewBuilder private var letterIndexSection: some View {
        Section {
            Picker("Indice lettere", selection: $letterIndexStyle) {
                ForEach(LetterIndexStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
        } header: {
            Text("Elenchi")
        } footer: {
            Text("L'indice A–Z a destra in Brani, Album e Artisti. Classico: quello di iOS, sempre visibile, lo scorrimento più fluido. A scomparsa: compare mentre scorri e sparisce poco dopo.")
        }
    }

    @ViewBuilder private var coverFlowSection: some View {
        Section {
            Toggle("Cover Flow in orizzontale", isOn: $landscapeCoverFlow)
            Toggle("Riapri il disco in ascolto", isOn: $coverFlowResumesPlaying)
                .disabled(!landscapeCoverFlow)
        } footer: {
            Text("Gira il telefono per sfogliare gli album come in Cover Flow; tocca una copertina per far uscire il disco e ascoltarlo. Se una canzone sta suonando, girando il telefono il Cover Flow si riapre sull'album in ascolto, con il disco fuori.")
        }
    }

    @ViewBuilder private var nowPlayingBackgroundSection: some View {
        Section {
            Toggle("Sfondo sfocato", isOn: $colorManager.nowPlayingBlurredBackground)
            Toggle("Casuale e Ripeti nel player", isOn: $playerShowsModeButtons)
        } header: {
            Text("Schermata Play")
        } footer: {
            Text("Lo sfondo della copertina nella schermata Play, sfocata o nitida. Casuale e Ripeti compaiono ai lati dei comandi di riproduzione, senza aprire il menu o la coda.")
        }
    }

    @ViewBuilder private var heartSection: some View {
        Section {
            Toggle("Cuore rosa solo nell'animazione", isOn: $heartFlashOnly)
        } header: {
            Text("Cuore")
        } footer: {
            Text("Toccando il cuore nel player si colora di rosa per un attimo e poi torna del colore dei comandi.")
        }
    }
    #endif

    @ViewBuilder private var audioOutputSection: some View {
        AudioOutputSection()
    }

    @ViewBuilder private var equalizerSection: some View {
        Section {
            EqualizerView()
        } header: {
            Text("Equalizzatore")
        } footer: {
            Text("Regola le frequenze audio per personalizzare il suono. Scegli un preset o regola manualmente ogni banda.")
        }
    }

    @ViewBuilder private var streamingSection: some View {
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

            Toggle("Alta risoluzione a 48 kHz", isOn: $hiResTo48k)
        } header: {
            Text("Qualità streaming")
        } footer: {
            Text("Seleziona la qualità di riproduzione. \"Originale\" trasmette senza conversione. I brani oltre i 48 kHz arrivano convertiti a 48 kHz, sempre senza perdita (FLAC): partono prima e su iPhone la differenza non si sente, l'uscita del telefono lavora a 48 kHz.")
        }
    }

    @ViewBuilder private var audioInfoSections: some View {
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
    }

    @ViewBuilder private var accountSection: some View {
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
    }

    @ViewBuilder private var downloadsSection: some View {
        Section {
            HStack {
                Label("Download offline", systemImage: "arrow.down.circle.fill")
                Spacer()
                Text(formatBytes(downloadSize))
                    .foregroundColor(.secondary)
            }

            if downloadManager.hasDownloads {
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
    }

    @ViewBuilder private var cacheSection: some View {
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
    }

    @ViewBuilder private var backupSection: some View {
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
    }

    @ViewBuilder private var artistsSection: some View {
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
    }

    /// One toggle per music library the account can see; the last one on stays on.
    @ViewBuilder private var musicLibrariesSection: some View {
        if musicLibraries.count > 1 {
            Section {
                ForEach(musicLibraries, id: \.Id) { library in
                    Toggle(library.Name, isOn: libraryBinding(library))
                        .disabled(isLastLibraryOn(library))
                }
            } header: {
                Text("Librerie musicali")
            } footer: {
                Text("Scegli quali librerie del server mostrare. Ne serve almeno una.")
            }
        }
    }

    private func isLastLibraryOn(_ library: LibraryView) -> Bool {
        musicLibraries.allSatisfy { $0.Id == library.Id || disabledLibraries.contains($0.Id) }
    }

    private func libraryBinding(_ library: LibraryView) -> Binding<Bool> {
        Binding(
            get: { !disabledLibraries.contains(library.Id) },
            set: { isOn in
                guard let api = viewModel.apiService else { return }
                MusicLibrarySelection.setEnabled(isOn, id: library.Id, in: musicLibraries, scope: api.librarySelectionScope)
                updateDisabledLibraries(scope: api.librarySelectionScope)
                Task {
                    await viewModel.fetchAllLibraryData()
                    await viewModel.fetchRecentlyPlayedTracks()
                }
            }
        )
    }

    private func loadMusicLibraries() async {
        guard let api = viewModel.apiService, let all = try? await api.fetchMusicLibraries() else { return }
        musicLibraries = all
        updateDisabledLibraries(scope: api.librarySelectionScope)
    }

    /// What the toggles show is what is really in use (a stored "all off" counts as all on).
    private func updateDisabledLibraries(scope: String) {
        let on = Set(MusicLibrarySelection.enabled(from: musicLibraries, scope: scope).map(\.Id))
        disabledLibraries = Set(musicLibraries.map(\.Id)).subtracting(on)
    }

    @ViewBuilder private var librarySyncSection: some View {
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
    }

    @ViewBuilder private var aboutSection: some View {
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

// Landscape Cover Flow switch, read by SettingsView and ContentView.
enum CoverFlowSettings {
    static let storageKey = "landscapeCoverFlow"
    /// Turning the phone sideways while music plays opens the Cover Flow on the playing album with the disc out. Default true. In the settings backup.
    static let resumeKey = "coverFlowResumesPlaying"
}
