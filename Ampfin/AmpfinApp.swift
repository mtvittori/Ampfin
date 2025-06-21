import SwiftUI
import AVFoundation
import AVKit

@main
struct JellyfinMusicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

// MARK: - API Service
class JellyfinAPI: ObservableObject {
    // Liste dati
    @Published var audioItems: [AudioItem] = []
    @Published var albums: [AlbumItem] = []
    @Published var artists: [ArtistItem] = []
    @Published var genres: [GenreItem] = []
    
    // Stati UI
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isLoggedIn = false
    @Published var selectedAlbumTracks: [AudioItem] = []
    @Published var isLoadingAlbum: Bool = false
    @Published var allAvailableGenres: [String] = []

    
    // Stati del player
       @Published var currentlyPlayingItem: AudioItem?
       @Published var isPlaying: Bool = false
       @Published var currentTime: TimeInterval = 0
       
       // NUOVO: Coda di riproduzione per gestire album, shuffle, etc.
       @Published private(set) var playQueue: [AudioItem] = []
    
    private var player: AVPlayer?
    private var timeObserverToken: Any?
    
    private var token: String = ""
    private var userId: String = ""
    private var serverUrl: String = "http://192.168.0.106:8096"
    
    // Chiavi per UserDefaults
      private enum StorageKeys {
          static let token = "jellyfin_accesstoken"
          static let userId = "jellyfin_userid"
          static let serverUrl = "jellyfin_serverurl"
      }
      
      // NUOVO: Costruttore per caricare le credenziali all'avvio
      init() {
          loadCredentials()
          
          if isLoggedIn {
              print("Sessione ripristinata per l'utente \(userId). Caricamento dati...")
              fetchAllLibraryData()
          } else {
              print("Nessuna sessione trovata. In attesa di login.")
          }
      }
    func fetchAlbumTracks(albumId: String) {
         isLoadingAlbum = true; selectedAlbumTracks = []
         let urlString = "\(serverUrl)/Users/\(userId)/Items?ParentId=\(albumId)&SortBy=SortName&SortOrder=Ascending&IncludeItemTypes=Audio&Fields=AlbumArtists,Artists,MediaSources,AlbumId"
         fetchItems(urlString: urlString, decodingType: AudioResponse.self) { result in
             DispatchQueue.main.async {
                 if let items = result?.Items { self.selectedAlbumTracks = items }
                 self.isLoadingAlbum = false
             }
         }
     }
      
      // MARK: - Authentication
      func login(username: String, password: String) {
          isLoading = true; errorMessage = nil
          guard let url = URL(string: "\(serverUrl)/Users/AuthenticateByName") else {
              DispatchQueue.main.async { self.errorMessage = "URL non valido"; self.isLoading = false }; return
          }
          var request = URLRequest(url: url)
          request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
          let deviceId = UUID().uuidString
          let authHeader = "MediaBrowser Client=\"Ampfin\", Device=\"macOS\", DeviceId=\"\(deviceId)\", Version=\"1.0.0\""
          request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
          struct LoginRequest: Codable { let Username: String; let Pw: String }
          let loginBody = LoginRequest(Username: username, Pw: password)
          do { request.httpBody = try JSONEncoder().encode(loginBody) }
          catch { DispatchQueue.main.async { self.errorMessage = "Errore richiesta: \(error)"; self.isLoading = false }; return }

          URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
              DispatchQueue.main.async {
                  self?.isLoading = false
                  if let error = error { self?.errorMessage = "Errore connessione: \(error)"; return }
                  guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                      self?.errorMessage = "Login fallito (Status: \((response as? HTTPURLResponse)?.statusCode ?? 0))"; return
                  }
                  guard let data = data else { self?.errorMessage = "Nessun dato dal server"; return }
                  do {
                      let result = try JSONDecoder().decode(LoginResponse.self, from: data)
                      self?.token = result.AccessToken
                      self?.userId = result.User.Id
                      self?.isLoggedIn = true
                      
                      // Salva le credenziali dopo il login
                      self?.saveCredentials()
                      
                      self?.fetchAllLibraryData()
                  } catch { self?.errorMessage = "Errore parsing login: \(error)" }
              }
          }.resume()
      }
      
      func logout() {
          stop()
          token = ""
          userId = ""
          audioItems = []
          albums = []
          artists = []
          allAvailableGenres = []
          isLoggedIn = false
          errorMessage = nil
          
          // Cancella le credenziali al logout
          clearCredentials()
      }
      
      // MARK: - Persistent Storage Helpers
      private func saveCredentials() {
          let defaults = UserDefaults.standard
          defaults.set(token, forKey: StorageKeys.token)
          defaults.set(userId, forKey: StorageKeys.userId)
          defaults.set(serverUrl, forKey: StorageKeys.serverUrl)
          print("Credenziali salvate.")
      }
      
      private func loadCredentials() {
          let defaults = UserDefaults.standard
          let savedToken = defaults.string(forKey: StorageKeys.token) ?? ""
          let savedUserId = defaults.string(forKey: StorageKeys.userId) ?? ""
          
          if !savedToken.isEmpty && !savedUserId.isEmpty {
              self.token = savedToken
              self.userId = savedUserId
              // Carica anche l'URL del server, con un fallback al valore hardcoded se non esiste
              self.serverUrl = defaults.string(forKey: StorageKeys.serverUrl) ?? self.serverUrl
              self.isLoggedIn = true
          }
      }
      
      private func clearCredentials() {
          let defaults = UserDefaults.standard
          defaults.removeObject(forKey: StorageKeys.token)
          defaults.removeObject(forKey: StorageKeys.userId)
          defaults.removeObject(forKey: StorageKeys.serverUrl)
          print("Credenziali cancellate.")
      }
      
        
        // MARK: - Data Fetching
        
        func fetchAllLibraryData() {
            guard isLoggedIn else { return }
            isLoading = true
            errorMessage = nil
            fetchMusicLibraryId { [weak self] libraryId in
                guard let self = self, let libraryId = libraryId else {
                    DispatchQueue.main.async {
                        self?.isLoading = false
                        if self?.errorMessage == nil { self?.errorMessage = "ID della libreria musicale non trovato." }
                    }
                    return
                }
                let group = DispatchGroup()
                group.enter(); self.fetchTracks(from: libraryId) { group.leave() }
                group.enter(); self.fetchAlbums(from: libraryId) { group.leave() }
                group.enter(); self.fetchArtists(from: libraryId) { group.leave() }
                group.enter(); self.fetchGenres(from: libraryId) { group.leave() }
                group.notify(queue: .main) {
                    self.isLoading = false
                    print("Tutti i dati della libreria sono stati caricati.")
                }
            }
        }
        
        private func fetchMusicLibraryId(completion: @escaping (String?) -> Void) {
            guard let url = URL(string: "\(serverUrl)/Users/\(userId)/Views") else { completion(nil); return }
            var request = URLRequest(url: url)
            addAuthHeader(to: &request)
            URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                guard let data = data else { completion(nil); return }
                do {
                    let result = try JSONDecoder().decode(UserViewsResponse.self, from: data)
                    if let musicLibrary = result.Items.first(where: { $0.CollectionType == "music" }) {
                        completion(musicLibrary.Id)
                    } else {
                        DispatchQueue.main.async { self?.errorMessage = "Nessuna libreria musicale trovata." }
                        completion(nil)
                    }
                } catch {
                    DispatchQueue.main.async { self?.errorMessage = "Errore decodifica librerie: \(error)" }
                    completion(nil)
                }
            }.resume()
        }

    private func fetchTracks(from libraryId: String, completion: @escaping () -> Void) {
           let urlString = "\(serverUrl)/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=Audio&Recursive=true&Fields=AlbumArtists,Artists,MediaSources,AlbumId,Genres&SortBy=SortName"
           fetchItems(urlString: urlString, decodingType: AudioResponse.self) { result in
               DispatchQueue.main.async {
                   if let items = result?.Items {
                       self.audioItems = items
                       // Estrai i generi unici da tutti i brani
                       let allGenres = items.compactMap { $0.Genres }.flatMap { $0 }
                       self.allAvailableGenres = Array(Set(allGenres)).sorted()
                   }
                   completion()
               }
           }
       }

        private func fetchAlbums(from libraryId: String, completion: @escaping () -> Void) {
            let urlString = "\(serverUrl)/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=MusicAlbum&Recursive=true&Fields=ProductionYear,AlbumArtists&SortBy=SortName"
            fetchItems(urlString: urlString, decodingType: AlbumResponse.self) { result in
                DispatchQueue.main.async {
                    if let items = result?.Items { self.albums = items }
                    completion()
                }
            }
        }
        
        private func fetchArtists(from libraryId: String, completion: @escaping () -> Void) {
            let urlString = "\(serverUrl)/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=MusicArtist&Recursive=true&SortBy=SortName"
            fetchItems(urlString: urlString, decodingType: ArtistResponse.self) { result in
                DispatchQueue.main.async {
                    if let items = result?.Items { self.artists = items }
                    completion()
                }
            }
        }
        
        private func fetchGenres(from libraryId: String, completion: @escaping () -> Void) {
            let urlString = "\(serverUrl)/Users/\(userId)/Items?ParentId=\(libraryId)&IncludeItemTypes=MusicGenre&Recursive=true&SortBy=SortName"
            fetchItems(urlString: urlString, decodingType: GenreResponse.self) { result in
                DispatchQueue.main.async {
                    if let items = result?.Items { self.genres = items }
                    completion()
                }
            }
        }
        
        private func fetchItems<T: Codable>(urlString: String, decodingType: T.Type, completion: @escaping (T?) -> Void) {
            guard let url = URL(string: urlString) else { completion(nil); return }
            var request = URLRequest(url: url)
            addAuthHeader(to: &request)
            URLSession.shared.dataTask(with: request) { data, response, error in
                guard let data = data, error == nil else { completion(nil); return }
                do {
                    let result = try JSONDecoder().decode(T.self, from: data)
                    completion(result)
                } catch {
                    print("Errore di decodifica per \(urlString): \(error)"); completion(nil)
                }
            }.resume()
        }
        
    func play(item: AudioItem, in queue: [AudioItem]) {
          self.playQueue = queue
          stopTimeObserver(); player?.pause()
          let streamUrlString = "\(serverUrl)/Audio/\(item.Id)/stream?static=true&api_key=\(token)"
          guard let url = URL(string: streamUrlString) else { return }
          player = AVPlayer(url: url); player?.play()
          currentlyPlayingItem = item; isPlaying = true; currentTime = 0
          startTimeObserver(); setupEndOfPlayNotification()
      }
      
      // Funzione per avviare un album in modalità casuale
      func playAlbumShuffled(tracks: [AudioItem]) {
          guard !tracks.isEmpty else { return }
          let shuffledQueue = tracks.shuffled()
          play(item: shuffledQueue.first!, in: shuffledQueue)
      }

      func togglePlayPause() { isPlaying.toggle(); if isPlaying { player?.play() } else { player?.pause() } }
      
      // forward() ora usa la playQueue
      func forward() {
          guard let currentItem = currentlyPlayingItem,
                let currentIndex = playQueue.firstIndex(where: { $0.id == currentItem.id }) else { return }
          
          let nextIndex = currentIndex + 1
          if nextIndex < playQueue.count {
              play(item: playQueue[nextIndex], in: playQueue)
          } else {
              // Fine della coda, ferma la riproduzione
              stop()
          }
      }
      
      // backward() ora usa la playQueue
      func backward() {
          guard let currentItem = currentlyPlayingItem,
                let currentIndex = playQueue.firstIndex(where: { $0.id == currentItem.id }) else { return }
          
          if currentTime > 3 {
              seek(to: 0)
          } else {
              let prevIndex = currentIndex - 1
              if prevIndex >= 0 {
                  play(item: playQueue[prevIndex], in: playQueue)
              } else {
                  seek(to: 0)
              }
          }
      }
        
        func seek(to time: TimeInterval) {
            player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
            currentTime = time
        }
        
        func stop() {
            player?.pause(); player = nil; currentlyPlayingItem = nil
            isPlaying = false; currentTime = 0; stopTimeObserver()
        }
        
        // MARK: - Helpers
        func artworkURL(for itemId: String, size: Int = 200) -> URL? {
            return URL(string: "\(serverUrl)/Items/\(itemId)/Images/Primary?maxHeight=\(size)&maxWidth=\(size)&quality=90&tag=&api_key=\(token)")
        }
        
        private func addAuthHeader(to request: inout URLRequest) {
            let authHeader = "MediaBrowser Client=\"Ampfin\", Device=\"macOS\", DeviceId=\"\(UUID().uuidString)\", Version=\"1.0.0\", Token=\"\(token)\""
            request.setValue(authHeader, forHTTPHeaderField: "X-Emby-Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        
        private func startTimeObserver() {
            let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
            timeObserverToken = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in self?.currentTime = time.seconds }
        }
        
        private func stopTimeObserver() {
            if let token = timeObserverToken { player?.removeTimeObserver(token); timeObserverToken = nil }
        }
        
        private func setupEndOfPlayNotification() {
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main) { [weak self] _ in self?.forward() }
        }
    }

// MARK: - Main Content View
struct ContentView: View {
    @StateObject private var api = JellyfinAPI()
    private let playerBarHeight: CGFloat = 90 // Altezza della barra del player per il padding
    
    var body: some View {
        ZStack(alignment: .bottom) {
            if !api.isLoggedIn {
                LoginView(api: api)
            } else {
                // Livello 1: TabView principale
                TabView {
                    TracksView()
                        .tabItem { Label("Brani", systemImage: "music.note.list") }
                    
                    AlbumsView()
                        .tabItem { Label("Album", systemImage: "square.stack.fill") }
                    
                    ArtistsView()
                        .tabItem { Label("Artisti", systemImage: "music.mic") }
                    
                    GenresView()
                        .tabItem { Label("Generi", systemImage: "guitars.fill") }
                }
                .glassEffect()
                // Aggiunge spazio in basso per non far coprire i contenuti dal player
                .padding(.bottom, api.currentlyPlayingItem != nil ? playerBarHeight : 0)

                // Livello 2: Player in overlay
                if let playingItem = api.currentlyPlayingItem {
                    MusicPlayerView(
                        item: playingItem,
                        isPlaying: api.isPlaying,
                        currentTime: api.currentTime,
                        duration: playingItem.duration ?? 0,
                        artworkURL: api.artworkURL(for: playingItem.id, size: 100),
                        onPlayPause: api.togglePlayPause,
                        onBackward: api.backward,
                        onForward: api.forward,
                        onSeek: api.seek
                    )
                    .frame(height: playerBarHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .glassEffect()
        .animation(.default, value: api.currentlyPlayingItem != nil)
        .environmentObject(api)
        .frame(minWidth: 800, minHeight: 600)
    }
}

// MARK: - Login View
struct LoginView: View {
    @ObservedObject var api: JellyfinAPI
    @State private var username = ""
    @State private var password = ""
    
    var body: some View {
        VStack(spacing: 15) {
            Text("Accedi a Jellyfin")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            TextField("Username", text: $username)
                .textFieldStyle(RoundedBorderTextFieldStyle()).frame(maxWidth: 300)
            
            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle()).frame(maxWidth: 300)
            
            if let errorMessage = api.errorMessage {
                Text(errorMessage).foregroundColor(.red).font(.caption).multilineTextAlignment(.center)
            }
            
            Button("Login") {
                api.login(username: username, password: password)
            }
            .disabled(username.isEmpty || password.isEmpty || api.isLoading)
            .buttonStyle(.borderedProminent).controlSize(.large)
            
            if api.isLoading {
                ProgressView("Caricamento libreria...")
            }
        }
    }
}


// MARK: - Tab Views

struct TracksView: View {
    @EnvironmentObject var api: JellyfinAPI
    @State private var searchText = ""

    // Proprietà calcolata per filtrare i brani
    var filteredTracks: [AudioItem] {
        if searchText.isEmpty {
            return api.audioItems
        } else {
            return api.audioItems.filter {
                $0.Name.localizedCaseInsensitiveContains(searchText) ||
                ($0.mainArtistName ?? "").localizedCaseInsensitiveContains(searchText) ||
                ($0.Album ?? "").localizedCaseInsensitiveContains(searchText)
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Barra di ricerca
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Cerca in Brani, Artisti, Album...", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.unemphasizedSelectedContentBackgroundColor))
            .cornerRadius(8)
            .padding()

            // Lista dei brani
            List(filteredTracks) { item in
                TrackRowView(item: item)
                    .onTapGesture {
                        api.play(item: item, in: filteredTracks)
                    }
            }
            .listStyle(.plain)
        }
        .navigationTitle("Brani") // Anche se non c'è una NavigationBar, è utile per il titolo della finestra
        .toolbar { ToolbarItem { Button("Logout") { api.logout() } } }
    }
}

// MARK: - Albums Tab (MODIFICATA)
// La vista per la griglia, come era in origine.
struct AlbumGridItemView: View {
    @EnvironmentObject var api: JellyfinAPI
    let album: AlbumItem
    
    var body: some View {
        VStack(alignment: .leading) {
            AsyncImage(url: api.artworkURL(for: album.id, size: 300)) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Rectangle().foregroundColor(.secondary.opacity(0.3))
                    .overlay(Image(systemName: "music.note").font(.largeTitle))
            }
            .cornerRadius(8)
            .shadow(radius: 4)
            
            Text(album.Name).font(.headline).lineLimit(1)
            Text(album.AlbumArtist ?? "Artista Sconosciuto").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
        }
    }
}

// Vista Album RIPRISTINATA alla griglia.
struct AlbumsView: View {
    @EnvironmentObject var api: JellyfinAPI
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 20)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(api.albums) { album in
                        NavigationLink(value: album) {
                            AlbumGridItemView(album: album)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Album")
            .navigationDestination(for: AlbumItem.self) { album in
                AlbumTracksListView(album: album)
            }
        }
    }
}

// Vista dettaglio album COMPLETAMENTE rifatta.
struct AlbumTracksListView: View {
    @EnvironmentObject var api: JellyfinAPI
    let album: AlbumItem

    // Formattatore per la durata totale e per le singole tracce
    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    // Calcola la durata totale dell'album
    private var totalDurationString: String {
        let totalSeconds = api.selectedAlbumTracks.compactMap { $0.duration }.reduce(0, +)
        let totalMinutes = Int(totalSeconds) / 60
        return "\(totalMinutes) minuti"
    }

    var body: some View {
        // Usiamo una List per avere lo scrolling unico per header e brani
        List {
            // Sezione Header
            albumHeader
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets()) // Rimuove il padding di default
                .padding(.bottom)

            // Sezione Brani
            if api.isLoadingAlbum {
                ProgressView()
            } else {
                ForEach(Array(api.selectedAlbumTracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track: track, index: index)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(album.Name) // Mantiene il titolo nella barra della finestra
        .onAppear {
            // Carica i brani solo se non sono già stati caricati per questo album
            if api.selectedAlbumTracks.first?.AlbumId != album.id {
                api.fetchAlbumTracks(albumId: album.id)
            }
        }
    }
    
    // Header con copertina grande e pulsanti
    private var albumHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 20) {
                AsyncImage(url: api.artworkURL(for: album.id, size: 360)) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: { Rectangle().fill(.gray.opacity(0.3)).overlay(Image(systemName: "music.note")) }
                    .frame(width: 180, height: 180).cornerRadius(8).shadow(radius: 5)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.Name).font(.title).fontWeight(.bold)
                    Text(album.AlbumArtist ?? "Artista Sconosciuto").font(.title3).foregroundColor(.accentColor)
                    
                    HStack(spacing: 8) {
                        Text("\(album.ProductionYear ?? 0) • \(api.selectedAlbumTracks.count) brani")
                        if api.selectedAlbumTracks.first?.isLossless == true {
                             Text("Lossless").font(.caption).fontWeight(.bold).foregroundColor(.secondary).padding(.horizontal, 6).padding(.vertical, 3).overlay(Capsule().stroke(Color.secondary, lineWidth: 1))
                        }
                    }.font(.caption).foregroundColor(.gray).padding(.top, 5)
                }.padding(.top, 5)
                Spacer()
            }
            
            // Pulsanti Play e Shuffle
            HStack {
                Button { if let firstTrack = api.selectedAlbumTracks.first { api.play(item: firstTrack, in: api.selectedAlbumTracks) } } label: { Label("Riproduci", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
                Button { api.playAlbumShuffled(tracks: api.selectedAlbumTracks) } label: { Label("Casuale", systemImage: "shuffle").frame(maxWidth: .infinity) }.buttonStyle(.bordered).controlSize(.large)
            }
        }.padding([.horizontal, .top])
    }
    
    // Riga della traccia con più spazio
    private func trackRow(track: AudioItem, index: Int) -> some View {
        HStack {
            Text("\(index + 1)").font(.callout).foregroundColor(.secondary).frame(minWidth: 25, alignment: .trailing)
            Text(track.Name).font(.body)
            Spacer()
            if api.currentlyPlayingItem?.id == track.id { Image(systemName: "waveform").foregroundColor(.accentColor) }
            Text(formatTime(track.duration ?? 0)).font(.callout).foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { api.play(item: track, in: api.selectedAlbumTracks) }
    }
}

// MARK: - Artists Tab (MODIFICATA)
struct ArtistsView: View {
    @EnvironmentObject var api: JellyfinAPI

    var body: some View {
        NavigationStack {
            List(api.artists) { artist in
                NavigationLink(value: artist) {
                    Text(artist.Name)
                }
            }
            .navigationTitle("Artisti")
            .navigationDestination(for: ArtistItem.self) { artist in
                ArtistAlbumsView(artist: artist)
            }
        }
    }
}

// NUOVA VISTA: Mostra gli album di un artista specifico
struct ArtistAlbumsView: View {
    @EnvironmentObject var api: JellyfinAPI
    let artist: ArtistItem

    // Filtra gli album per l'artista selezionato
    var filteredAlbums: [AlbumItem] {
        api.albums.filter { $0.AlbumArtist == artist.Name }
    }

    var body: some View {
        // Usa la vista a griglia per coerenza
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 20)]) {
                ForEach(filteredAlbums) { album in
                    NavigationLink(value: album) {
                        AlbumGridItemView(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(artist.Name)
        // La navigationDestination per AlbumItem è già nella tab principale, non serve ripeterla
    }
}


// MARK: - Genres Tab (MODIFICATA)
struct GenresView: View {
    @EnvironmentObject var api: JellyfinAPI

    var body: some View {
        NavigationStack {
            List(api.allAvailableGenres, id: \.self) { genreName in
                NavigationLink(genreName, value: genreName)
            }
            .navigationTitle("Generi")
            .navigationDestination(for: String.self) { genreName in
                GenreArtistsView(genreName: genreName)
            }
        }
    }
}

// NUOVA VISTA: Mostra gli artisti per un genere specifico
struct GenreArtistsView: View {
    @EnvironmentObject var api: JellyfinAPI
    let genreName: String

    // Filtra gli artisti per il genere selezionato
    var filteredArtists: [ArtistItem] {
        // 1. Trova tutti i brani che appartengono al genere selezionato
        let tracksInGenre = api.audioItems.filter { $0.Genres?.contains(genreName) ?? false }
        
        // 2. Estrai tutti gli ID degli artisti da questi brani
        let artistIds = Set(tracksInGenre.compactMap { $0.AlbumArtists?.first?.Id })
        
        // 3. Filtra la lista principale degli artisti usando gli ID trovati
        return api.artists.filter { artistIds.contains($0.id) }.sorted { $0.Name < $1.Name }
    }

    var body: some View {
        List(filteredArtists) { artist in
            NavigationLink(value: artist) {
                Text(artist.Name)
            }
        }
        .navigationTitle(genreName)
        // La navigationDestination per ArtistItem è già nella tab Artisti, non serve ripeterla
    }
}



struct AlbumDetailView: View {
    @EnvironmentObject var api: JellyfinAPI
    let item: AudioItem

    var body: some View {
        let track = api.selectedAlbumTracks.first ?? item
        VStack {
            HStack(alignment: .top, spacing: 20) {
                AsyncImage(url: api.artworkURL(for: track.id)) { image in
                    image.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    Image(systemName: "music.note").font(.system(size: 40))
                }
                .frame(width: 150, height: 150).cornerRadius(8)

                VStack(alignment: .leading) {
                    Text(track.Album ?? "Album Sconosciuto").font(.largeTitle).fontWeight(.bold)
                    Text(track.mainArtistName ?? "Artista Sconosciuto").font(.title2).foregroundColor(.secondary)
                }
                Spacer()
            }.padding()

            if !api.selectedAlbumTracks.isEmpty {
                List(api.selectedAlbumTracks, id: \.id) { track in
                    HStack {
                        Text(track.Name)
                        Spacer()
                        if api.currentlyPlayingItem?.id == track.id {
                            Image(systemName: "waveform").foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { api.play(item: track, in: api.selectedAlbumTracks) }
                }
            } else if api.isLoadingAlbum {
                ProgressView()
            }
        }
    }
}

struct TrackRowView: View {
    @EnvironmentObject var api: JellyfinAPI
    let item: AudioItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: api.artworkURL(for: item.id, size: 80)) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.2)).overlay(Image(systemName: "music.note"))
            }
            .frame(width: 45, height: 45)
            .cornerRadius(6)

            VStack(alignment: .leading) {
                Text(item.Name).fontWeight(.medium)
                HStack(spacing: 4) {
                    Text(item.mainArtistName ?? "Artista Sconosciuto").foregroundColor(.secondary)
                    Text("•").foregroundColor(.secondary)
                    Text(item.Album ?? "Album Sconosciuto").foregroundColor(.secondary)
                }
                .font(.caption)
            }
            
            Spacer()

            if let genres = item.Genres, let firstGenre = genres.first {
                 Text(firstGenre)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.2))
                    .cornerRadius(10)
            }
            
            if api.currentlyPlayingItem?.id == item.id {
                Image(systemName: "waveform").foregroundColor(.accentColor).font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}


// MARK: - AirPlay View (CORRETTO PER MACOS)
struct AirPlayView: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        // Su macOS, non sono necessarie opzioni di stile.
        // Basta creare e restituire la vista.
        let routePickerView = AVRoutePickerView()
        return routePickerView
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        // Nessun aggiornamento necessario per questo caso.
    }
}

// MARK: - Player View (RIFATTO PER OVERLAY)
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
    
    @State private var sliderValue: Double = 0
    @State private var isEditingSlider: Bool = false
    
    private func formatTime(_ time: TimeInterval) -> String {
        guard !time.isNaN && !time.isInfinite && time >= 0 else { return "0:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Barra di scorrimento
            Slider(value: Binding(get: { isEditingSlider ? sliderValue : currentTime }, set: { sliderValue = $0 }),
                   in: 0...(duration > 0 ? duration : 1),
                   onEditingChanged: { editing in
                       isEditingSlider = editing
                       if !editing { onSeek(sliderValue) }
                   })
            
            // Controlli principali
            HStack(spacing: 15) {
                AsyncImage(url: artworkURL) { image in image.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { Rectangle().fill(.gray.opacity(0.2)).overlay(Image(systemName: "music.note")) }
                .frame(width: 55, height: 55).cornerRadius(6)
                
                VStack(alignment: .leading) {
                    Text(item.Name).font(.headline).lineLimit(1)
                    if let artist = item.mainArtistName {
                        Text(artist).font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                
                Spacer()
                
                HStack(spacing: 20) {
                    Button(action: onBackward) { Image(systemName: "backward.fill").font(.title2) }.buttonStyle(.plain)
                    Button(action: onPlayPause) { Image(systemName: isPlaying ? "pause.fill" : "play.fill").font(.largeTitle) }.buttonStyle(.plain)
                    Button(action: onForward) { Image(systemName: "forward.fill").font(.title2) }.buttonStyle(.plain)
                    AirPlayView().frame(width: 30, height: 30)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        .background(.regularMaterial) // Effetto vetro stile Apple
    }
}


// MARK: - Codable Models
struct LoginResponse: Codable { let AccessToken: String; let User: JellyfinUser }
struct JellyfinUser: Codable { let Id: String; let Name: String? }
struct UserViewsResponse: Codable { let Items: [LibraryView] }
struct LibraryView: Codable { let Name: String; let Id: String; let CollectionType: String? }
struct AudioResponse: Codable { let Items: [AudioItem] }
struct AlbumResponse: Codable { let Items: [AlbumItem] }
struct ArtistResponse: Codable { let Items: [ArtistItem] }
struct ArtistInfo: Codable { let Name: String; let Id: String }
struct GenreResponse: Codable { let Items: [GenreItem] }


// NUOVA STRUCT DEFINITA CORRETTAMENTE
struct MediaSourceInfo: Codable {
    let Container: String?
}

// AudioItem CORRETTO (rimosso CodingKeys)
struct AudioItem: Codable, Identifiable {
    let Id: String
    var id: String { Id }
    
    let Name: String
    let Artists: [String]?
    let AlbumArtists: [ArtistInfo]?
    let Album: String?
    let RunTimeTicks: Int64?
    let AlbumId: String?
    let Genres: [String]?
    let MediaSources: [MediaSourceInfo]? // Ora il tipo è conosciuto
    
    var mainArtistName: String? { AlbumArtists?.first?.Name ?? Artists?.first }
    var duration: TimeInterval? {
        guard let ticks = RunTimeTicks else { return nil }
        return TimeInterval(ticks) / 10_000_000.0
    }
    
    var isLossless: Bool {
        guard let container = MediaSources?.first?.Container?.lowercased() else { return false }
        // m4a può contenere ALAC (Apple Lossless) o AAC (lossy),
        // ma spesso viene usato per musica di alta qualità da iTunes/Apple Music.
        // Lo consideriamo "lossless" per l'etichetta.
        return container == "flac" || container == "m4a"
    }
}

struct AlbumItem: Codable, Identifiable, Hashable {
    let Id: String; var id: String { Id }
    let Name: String
    let AlbumArtist: String?
    let ProductionYear: Int?
    func hash(into hasher: inout Hasher) { hasher.combine(Id) }
    static func == (lhs: AlbumItem, rhs: AlbumItem) -> Bool { lhs.Id == rhs.Id }
}

// REINTRODOTTA: La struct per il modello del genere
struct GenreItem: Codable, Identifiable {
    let Id: String; var id: String { Id }
    let Name: String
}

// MODIFICATO: Aggiunto Hashable per la navigazione
struct ArtistItem: Codable, Identifiable, Hashable {
    let Id: String; var id: String { Id }
    let Name: String
    func hash(into hasher: inout Hasher) { hasher.combine(Id) }
    static func == (lhs: ArtistItem, rhs: ArtistItem) -> Bool { lhs.Id == rhs.Id }
}
