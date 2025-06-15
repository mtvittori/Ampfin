import SwiftUI
import AVFoundation

@main
struct JellyfinMusicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

class JellyfinAPI: ObservableObject {
    @Published var audioItems: [AudioItem] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isLoggedIn = false
    @Published var currentlyPlaying: String?
    @Published var selectedAlbumTracks: [AudioItem] = []
    @Published var isLoadingAlbum: Bool = false
    
    // Nuovi stati per player
    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    
    private var token: String = ""
    private var userId: String = ""
    private var serverUrl: String = "http://192.168.0.106:8096"
    
    func login(username: String, password: String) {
        isLoading = true
        errorMessage = nil

        guard let url = URL(string: "\(serverUrl)/Users/AuthenticateByName") else {
            DispatchQueue.main.async {
                self.errorMessage = "URL del server non valido"
                self.isLoading = false
            }
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let deviceId = UUID().uuidString
        let clientName = "Ampfin"
        let clientVersion = "1.0.0"
        let deviceName = "macOS"
        let authHeader = "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        
        struct LoginRequest: Codable {
            let Username: String
            let Pw: String
        }
        
        let loginBody = LoginRequest(Username: username, Pw: password)

        do {
            request.httpBody = try JSONEncoder().encode(loginBody)
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Errore nella preparazione della richiesta: \(error.localizedDescription)"
                self.isLoading = false
            }
            return
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    self?.errorMessage = "Errore di connessione: \(error.localizedDescription)"
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    if let data = data, let responseString = String(data: data, encoding: .utf8) {
                        self?.errorMessage = "Login fallito: \(responseString)"
                    } else {
                        self?.errorMessage = "Login fallito (Status: \((response as? HTTPURLResponse)?.statusCode ?? 0))"
                    }
                    return
                }

                guard let data = data else {
                    self?.errorMessage = "Nessun dato ricevuto dal server"
                    return
                }

                do {
                    let result = try JSONDecoder().decode(LoginResponse.self, from: data)
                    self?.token = result.AccessToken
                    self?.userId = result.User.Id
                    self?.isLoggedIn = true
                    self?.fetchAudio()
                } catch {
                    self?.errorMessage = "Errore nel parsing della risposta di login: \(error.localizedDescription)"
                }
            }
        }.resume()
    }
    
    func fetchAlbumTracks(albumId: String) {
        isLoadingAlbum = true
        selectedAlbumTracks = []

        guard let url = URL(string: "\(serverUrl)/Users/\(userId)/Items?ParentId=\(albumId)&SortBy=SortName&SortOrder=Ascending&IncludeItemTypes=Audio&Fields=AlbumArtists,Artists,MediaSources,AlbumId") else { return }

        var request = URLRequest(url: url)
        let authHeader = "MediaBrowser Client=\"Ampfin\", Device=\"macOS\", DeviceId=\"\(UUID().uuidString)\", Version=\"1.0.0\", Token=\"\(token)\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data else {
                DispatchQueue.main.async { self?.isLoadingAlbum = false }
                return
            }
            do {
                let result = try JSONDecoder().decode(AudioResponse.self, from: data)
                DispatchQueue.main.async {
                    self?.selectedAlbumTracks = result.Items
                    self?.isLoadingAlbum = false
                }
            } catch {
                DispatchQueue.main.async { self?.isLoadingAlbum = false }
            }
        }.resume()
    }
    
    func fetchAudio() {
        guard isLoggedIn else { return }
        
        isLoading = true
        errorMessage = nil
        
        fetchMusicLibraryId { [weak self] libraryId in
            guard let self = self else { return }
            
            guard let libraryId = libraryId else {
                // L'errore specifico viene già impostato dentro fetchMusicLibraryId
                DispatchQueue.main.async {
                    if self.errorMessage == nil {
                         self.errorMessage = "ID della libreria musicale non trovato."
                    }
                    self.isLoading = false
                }
                return
            }
            
            self.fetchTracks(from: libraryId)
        }
    }
    
    private func fetchMusicLibraryId(completion: @escaping (String?) -> Void) {
        guard let url = URL(string: "\(serverUrl)/Users/\(userId)/Views") else {
            completion(nil)
            return
        }
        
        var request = URLRequest(url: url)
        
        // --- USARE QUESTO METODO DI AUTENTICAZIONE UNIFICATO ---
        let authHeader = "MediaBrowser Client=\"Jellyfin Music App\", Device=\"macOS\", DeviceId=\"\(UUID().uuidString)\", Version=\"1.0.0\", Token=\"\(token)\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let data = data, error == nil,
                  let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                DispatchQueue.main.async { self?.errorMessage = "Errore nel fetch delle librerie." }
                completion(nil)
                return
            }

            do {
                // Ripristiniamo il parsing con Codable, più pulito e sicuro
                let result = try JSONDecoder().decode(UserViewsResponse.self, from: data)
                
                // Cerca la libreria per CollectionType, è più affidabile
                if let musicLibrary = result.Items.first(where: { $0.CollectionType == "music" }) {
                    print("Trovata libreria musicale con ID: \(musicLibrary.Id)")
                    completion(musicLibrary.Id)
                } else {
                    // Fallback sul nome se CollectionType fallisce
                    if let musicLibraryByName = result.Items.first(where: { $0.Name.lowercased() == "music" }) {
                        print("Trovata libreria musicale per NOME con ID: \(musicLibraryByName.Id)")
                        completion(musicLibraryByName.Id)
                    } else {
                        DispatchQueue.main.async { self?.errorMessage = "Nessuna libreria musicale trovata." }
                        completion(nil)
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.errorMessage = "Errore decodifica librerie: \(error.localizedDescription)" }
                completion(nil)
            }
        }.resume()
    }

    private func fetchTracks(from libraryId: String) {
        guard let url = URL(string: "\(serverUrl)/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=Audio&Recursive=true&Fields=AlbumArtists,Artists,MediaSources,AlbumId") else {
            DispatchQueue.main.async { self.errorMessage = "URL tracce non valido." }
            return
        }

        var request = URLRequest(url: url)
        
        // --- APPLICA ESATTAMENTE LO STESSO HEADER ANCHE QUI! ---
        // Questo è il fix principale.
        let authHeader = "MediaBrowser Client=\"Jellyfin Music App\", Device=\"macOS\", DeviceId=\"\(UUID().uuidString)\", Version=\"1.0.0\", Token=\"\(token)\""
        request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                guard let data = data, error == nil,
                      let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                    self?.errorMessage = "Errore nel caricamento tracce audio."
                    return
                }

                // Se i dati sono ancora vuoti con l'auth corretta, la libreria è davvero vuota
                if data.isEmpty {
                     self?.errorMessage = "La libreria musicale è stata trovata, ma non contiene tracce."
                     return
                }

                do {
                    let result = try JSONDecoder().decode(AudioResponse.self, from: data)
                    self?.audioItems = result.Items
                    if result.Items.isEmpty {
                        self?.errorMessage = "La libreria musicale è vuota."
                    }
                } catch {
                    self?.errorMessage = "Errore nel parsing audio: \(error.localizedDescription)"
                    print("Errore di decodifica audio: \(error)")
                }
            }
        }.resume()
    }
    
    // MARK: - Player controls and helpers
    
    func play(item: AudioItem) {
        // Stop previous player and remove observer
        stopTimeObserver()
        player?.pause()
        
        let streamUrlString = "\(serverUrl)/Audio/\(item.Id)/stream?static=true&api_key=\(token)"
        guard let url = URL(string: streamUrlString) else {
            errorMessage = "URL di streaming non valido"
            return
        }
        player = AVPlayer(url: url)
        player?.play()
        currentlyPlaying = item.Name
        isPlaying = true
        currentTime = 0
        
        // Add periodic time observer to update currentTime every 0.5 seconds
        if let player = player {
            let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
            timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                self?.currentTime = time.seconds
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player?.currentItem,
            queue: .main
        ) { [weak self] _ in
            self?.currentlyPlaying = nil
            self?.isPlaying = false
            self?.currentTime = 0
            self?.stopTimeObserver()
        }
    }
    
    func pause() {
        player?.pause()
        isPlaying = false
    }
    
    func resume() {
        player?.play()
        isPlaying = true
    }
    
    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            resume()
        }
    }
    
    func stop() {
        player?.pause()
        player = nil
        currentlyPlaying = nil
        isPlaying = false
        currentTime = 0
        stopTimeObserver()
    }
    
    func logout() {
        stop()
        token = ""
        userId = ""
        audioItems = []
        isLoggedIn = false
        errorMessage = nil
    }
    
    private func stopTimeObserver() {
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
    
    // Avanti: riproduce la traccia successiva nella lista
    func forward() {
        guard let currentName = currentlyPlaying else { return }
        guard let currentIndex = audioItems.firstIndex(where: { $0.Name == currentName }) else { return }
        let nextIndex = currentIndex + 1
        if nextIndex < audioItems.count {
            play(item: audioItems[nextIndex])
        }
    }
    
    // Indietro: riproduce la traccia precedente nella lista
    func backward() {
        guard let currentName = currentlyPlaying else { return }
        guard let currentIndex = audioItems.firstIndex(where: { $0.Name == currentName }) else { return }
        // Se siamo a 3 secondi o più, torna all'inizio della traccia, altrimenti vai alla traccia precedente
        if currentTime > 3 {
            seek(to: 0)
        } else {
            let prevIndex = currentIndex - 1
            if prevIndex >= 0 {
                play(item: audioItems[prevIndex])
            } else {
                seek(to: 0)
            }
        }
    }
    
    func seek(to time: TimeInterval) {
        let cmTime = CMTime(seconds: time, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: cmTime)
        currentTime = time
    }
    
    // Fornisce URL immagine copertina per un AudioItem
    func artworkURL(for item: AudioItem) -> URL? {
        return URL(string: "\(serverUrl)/Items/\(item.Id)/Images/Primary?maxHeight=200&maxWidth=200&quality=90&tag=&api_key=\(token)")
    }
}

struct ContentView: View {
    @StateObject private var api = JellyfinAPI()
    @State private var username = ""
    @State private var password = ""
    @State private var selectedItemID: String?
    @State private var selectedAlbumID: String?


    
    var body: some View {
            // Niente più NavigationView qui!
            VStack(spacing: 0) { // Usiamo un VStack come contenitore di base
                if !api.isLoggedIn {
                    // La vista di login può rimanere centrata
                    Spacer()
                    loginView
                    Spacer()
                } else {
                    // La vista della libreria ora occupa tutto lo spazio
                    musicLibraryView
                }
            }
            .frame(minWidth: 700, minHeight: 500) // Diamo una dimensione di base alla finestra
        }
    private var loginView: some View {
        VStack(spacing: 15) {
            Text("Accedi a Jellyfin")
                .font(.title2)
                .fontWeight(.semibold)
            
            TextField("Username", text: $username)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(maxWidth: 300)
            
            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(maxWidth: 300)
            
            if let errorMessage = api.errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            
            Button("Login") {
                api.login(username: username, password: password)
            }
            .disabled(username.isEmpty || password.isEmpty || api.isLoading)
            .buttonStyle(.borderedProminent)
            
            if api.isLoading {
                ProgressView("Accesso in corso...")
            }
        }
    }
    
    // Aggiungi questa nuova struct View dentro ContentView
    struct TrackDetailView: View {
        @EnvironmentObject var api: JellyfinAPI // Accede all'API per riprodurre
        let item: AudioItem

        var body: some View {
            VStack(spacing: 20) {
                Spacer()
                
                // Copertina grande
                AsyncImage(url: api.artworkURL(for: item)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Image(systemName: "music.note")
                        .font(.system(size: 100))
                        .foregroundColor(.secondary)
                }
                .frame(width: 300, height: 300)
                .cornerRadius(12)
                .shadow(radius: 10)

                // Info
                VStack {
                    Text(item.Name).font(.largeTitle).fontWeight(.bold)
                    if let artist = item.mainArtistName {
                        Text(artist).font(.title2).foregroundColor(.secondary)
                    }
                    if let album = item.Album {
                        Text(album).font(.title3).foregroundColor(.gray)
                    }
                }
                
                // Bottone Play grande
                Button(action: {
                    api.play(item: item)
                }) {
                    Label("Riproduci", systemImage: "play.fill")
                        .font(.title2)
                        .padding(.horizontal, 30)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                
                Spacer()
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    
    // All'interno di ContentView

    private var musicLibraryView: some View {
        NavigationSplitView {
            // --- COLONNA SINISTRA (Sidebar) ---
            // Questa parte del tuo codice era già corretta.
            List(api.audioItems, id: \.Id, selection: $selectedItemID) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.Name)
                        if let artist = item.mainArtistName {
                            Text(artist).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    if api.currentlyPlaying == item.Name {
                        Image(systemName: "waveform").foregroundColor(.accentColor)
                    }
                }
            }
            .navigationTitle("Libreria")
            .toolbar {
                ToolbarItem {
                    Button("Logout") { api.logout() }
                }
            }
            .onChange(of: selectedItemID) { oldId, newId in
                guard let newId = newId, let selectedItem = api.audioItems.first(where: { $0.Id == newId }) else { return }
                if let albumId = selectedItem.AlbumId {
                    api.fetchAlbumTracks(albumId: albumId)
                }
            }

        } detail: {
            // --- COLONNA DESTRA (Detail) - CORRETTA ---
            
            // 1. Prima controlliamo se c'è un elemento selezionato.
            if let selectedID = selectedItemID,
               let selectedItem = api.audioItems.first(where: { $0.Id == selectedID }) {
                
                // 2. Se c'è, usiamo un VStack per impilare la vista dei dettagli e il player.
                VStack(spacing: 0) {
                    // La vista dell'album occupa tutto lo spazio disponibile in alto.
                    AlbumDetailView(item: selectedItem)
                        .environmentObject(api)
                    
                    Spacer() // Spinge il player verso il basso
                    
                    // Il player appare solo se una canzone è in riproduzione.
                    if let playingName = api.currentlyPlaying,
                       let playingItem = api.audioItems.first(where: { $0.Name == playingName }) {
                        
                        Divider() // Linea di separazione
                        
                        MusicPlayerView(
                            item: playingItem,
                            isPlaying: api.isPlaying,
                            currentTime: api.currentTime,
                            duration: playingItem.duration ?? 0,
                            artworkURL: api.artworkURL(for: playingItem),
                            onPlayPause: { api.togglePlayPause() },
                            onBackward: { api.backward() },
                            onForward: { api.forward() },
                            onSeek: { time in api.seek(to: time) }
                        )
                    }
                }
                
            } else {
                // 3. Se non c'è nulla di selezionato, mostriamo il placeholder.
                Text("Seleziona una traccia dalla libreria")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // NUOVA VISTA DI DETTAGLIO CHE INCLUDE IL PLAYER
    // Sostituisci la TrackAndPlayerDetailView
    struct AlbumDetailView: View {
        @EnvironmentObject var api: JellyfinAPI
        let item: AudioItem

        var body: some View {
            // Prendi il primo brano per le info dell'album (copertina, nome, etc.)
            let track = api.selectedAlbumTracks.first ?? item
            VStack {
                // Info Album in alto
                HStack(alignment: .top, spacing: 20) {
                    AsyncImage(url: api.artworkURL(for: track)) { image in
                        image.resizable().aspectRatio(contentMode: .fit)
                    } placeholder: {
                        Image(systemName: "music.note").font(.system(size: 40))
                    }
                    .frame(width: 150, height: 150)
                    .cornerRadius(8)

                    VStack(alignment: .leading) {
                        Text(track.Album ?? "Album Sconosciuto")
                            .font(.largeTitle).fontWeight(.bold)
                        Text(track.mainArtistName ?? "Artista Sconosciuto")
                            .font(.title2).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding()

                // Lista delle canzoni dell'album
                if !api.selectedAlbumTracks.isEmpty {
                    List(api.selectedAlbumTracks, id: \.Id) { track in
                        HStack {
                            Text(track.Name)
                            Spacer()
                            if api.currentlyPlaying == track.Name {
                                Image(systemName: "waveform").foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle()) // Rende l'intera riga cliccabile
                        .onTapGesture {
                            api.play(item: track)
                        }
                    }
                } else if api.isLoadingAlbum {
                    ProgressView()
                } else {
                    Text("Seleziona una traccia per vedere l'album.")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
    
    // MARK: - MusicPlayerView interna
    
    struct MusicPlayerView: View {
        let item: AudioItem
        let isPlaying: Bool
        let currentTime: TimeInterval
        let duration: TimeInterval
        let artworkURL: URL?
        
        let onPlayPause: () -> Void
        let onBackward: () -> Void
        let onForward: () -> Void
        let onSeek: (TimeInterval) -> Void
        
        // Formatta il tempo in mm:ss
        private func formatTime(_ time: TimeInterval) -> String {
            guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
            let totalSeconds = Int(time)
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
        
        @State private var sliderValue: Double = 0
        @State private var isEditingSlider: Bool = false
        
        var body: some View {
            VStack(spacing: 8) { // Aggiusto un po' lo spacing per un look più pulito
                  HStack(spacing: 15) {
                    // Copertina
                    if let url = artworkURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 50, height: 50)
                                    .background(Color.gray.opacity(0.2))
                                    .cornerRadius(6)
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 50, height: 50)
                                    .cornerRadius(6)
                                    .clipped()
                            case .failure:
                                Image(systemName: "music.note")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 50, height: 50)
                                    .foregroundColor(.gray)
                                    .cornerRadius(6)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Image(systemName: "music.note")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 50, height: 50)
                            .foregroundColor(.gray)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(6)
                    }
                    
                    // Info brano e artista
                    VStack(alignment: .leading) {
                        Text(item.Name)
                            .font(.headline)
                            .lineLimit(1)
                        if let artist = item.mainArtistName {
                            Text(artist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    Spacer()
                    
                    // Controlli player
                      HStack(spacing: 16) {
                                     Button(action: onBackward) {
                                         Image(systemName: "backward.fill")
                                             .font(.title3)
                                     }
                                     .buttonStyle(.plain) // Stile pulito per i bottoni dentro il glass
                                     
                                     Button(action: onPlayPause) {
                                         Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                             .font(.title2)
                                     }
                                     .buttonStyle(.plain)
                                     .scaleEffect(1.1) // Rende il bottone play leggermente più grande
                                     
                                     Button(action: onForward) {
                                         Image(systemName: "forward.fill")
                                             .font(.title3)
                                     }
                                     .buttonStyle(.plain)
                                 }
                }
                // Barra di avanzamento con slider e tempi
                VStack(spacing: 2) {
                           Slider(value: Binding(get: {
                               isEditingSlider ? sliderValue : currentTime
                           }, set: { newValue in
                               sliderValue = newValue
                           }), in: 0...(duration > 0 ? duration : 1), onEditingChanged: { editing in
                               isEditingSlider = editing
                               if !editing { onSeek(sliderValue) }
                           })
                           
                           HStack {
                               Text(formatTime(isEditingSlider ? sliderValue : currentTime))
                               Spacer()
                               Text(formatTime(duration))
                           }
                           .font(.caption2) // Font più piccolo per i tempi
                           .foregroundColor(.secondary)
                       }
                   }
            .padding(12)
            .glassEffect()
            .padding()

        }
    }
}

// MARK: - Modelli

struct LoginResponse: Codable {
    let AccessToken: String
    let User: JellyfinUser
}

struct JellyfinUser: Codable {
    let Id: String
    let Name: String?
}

// --- HO AGGIUNTO QUESTE STRUCT PER GESTIRE LE LIBRERIE ---
struct UserViewsResponse: Codable {
    let Items: [LibraryView]
}

struct LibraryView: Codable {
    let Name: String
    let Id: String
    let CollectionType: String?
}
// --- FINE AGGIUNTA ---

struct AudioResponse: Codable {
    let Items: [AudioItem]
    let TotalRecordCount: Int?
}

struct ArtistInfo: Codable {
    let Name: String
    let Id: String
}

struct AudioItem: Codable {
    let Id: String
    let Name: String
    let Artists: [String]?
    let AlbumArtists: [ArtistInfo]?
    let Album: String?
    let ItemType: String
    let MediaType: String?
    let RunTimeTicks: Int64?
    let AlbumId: String?
    
    enum CodingKeys: String, CodingKey {
        case Id, Name, Artists, AlbumArtists, Album, MediaType, RunTimeTicks
        case ItemType = "Type"
        case AlbumId
    }
    
    var mainArtistName: String? {
        return AlbumArtists?.first?.Name ?? Artists?.first
    }
    
    var duration: TimeInterval? {
        guard let ticks = RunTimeTicks else { return nil }
        return TimeInterval(ticks) / 10_000_000.0
    }
    
    /*
    /// URL copertina costruita dinamicamente tramite JellyfinAPI singleton con token e serverUrl
    var artworkURL: URL? {
        // Accesso al singleton JellyfinAPI per serverUrl e token
        guard let api = AudioItem.apiInstance else { return nil }
        return URL(string: "\(api.serverUrl)/Items/\(Id)/Images/Primary?maxHeight=200&maxWidth=200&quality=90&tag=&api_key=\(api.token)")
    }
    */
    
    /// Reference a JellyfinAPI singleton per costruire URL
    private static var apiInstance: JellyfinAPI? {
        // Tentativo di recuperare l'istanza condivisa da qualche parte
        // In questa app è un StateObject in ContentView, quindi per sicurezza passiamo sempre artworkURL da JellyfinAPI artworkURL(for:) invece di usare qui.
        // Questa proprietà è usata solo per fallback, quindi ritorniamo nil per evitare confusione.
        return nil
    }
}

