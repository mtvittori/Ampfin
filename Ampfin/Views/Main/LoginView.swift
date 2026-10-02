import SwiftUI

struct LoginView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var username = ""
    @State private var password = ""
    @State private var serverUrlLocal = ""
    @StateObject private var discoveryService = JellyfinDiscoveryService()
    
    private let fieldMaxWidth: CGFloat = 380
    
    private var trimmedServerUrl: String {
        serverUrlLocal.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var isServerUrlValid: Bool {
        let t = trimmedServerUrl.lowercased()
        return !t.isEmpty && (t.hasPrefix("http://") || t.hasPrefix("https://"))
    }
    
    @State private var showTestSuccess: Bool = false
    @State private var showTestFailure: Bool = false
    @State private var showingTestAlert: Bool = false
    
    var body: some View {
        #if os(macOS)
        macOSBody
        #else
        iOSBody
        #endif
    }

    // MARK: - iOS Layout

    #if os(iOS)
    private var iOSBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer().frame(height: 40)

                // Header
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundStyle(.primary)
                    Text("amplifin")
                        .font(.largeTitle).fontWeight(.bold)
                    Text("Accedi al tuo server Jellyfin")
                        .font(.subheadline).foregroundColor(.secondary)
                }

                // Form
                VStack(spacing: 16) {
                    // Server URL
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL").font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            TextField("http://192.168.0.106:8096", text: $serverUrlLocal)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(12)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .onChange(of: serverUrlLocal) {
                                    showTestSuccess = false
                                    showTestFailure = false
                                }
                                .onSubmit {
                                    viewModel.updateServerUrl(serverUrlLocal)
                                }

                            Button {
                                viewModel.updateServerUrl(serverUrlLocal)
                                testConnection()
                            } label: {
                                if viewModel.isTestingConnection {
                                    ProgressView().frame(width: 44, height: 44)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .frame(width: 44, height: 44)
                                }
                            }
                            .disabled(trimmedServerUrl.isEmpty || viewModel.isTestingConnection)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                        }

                        connectionStatus
                    }

                    // Network discovery
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            discoveryService.startDiscovery()
                        } label: {
                            HStack {
                                if discoveryService.isSearching {
                                    ProgressView()
                                        .padding(.trailing, 4)
                                } else {
                                    Image(systemName: "magnifyingglass.circle")
                                }
                                Text(discoveryService.isSearching ? "Ricerca in corso..." : "Cerca server sulla rete")
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .disabled(discoveryService.isSearching)
                        .buttonStyle(.glass)
                        .controlSize(.regular)

                        if !discoveryService.discoveredServers.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(discoveryService.discoveredServers) { server in
                                    Button {
                                        serverUrlLocal = server.address
                                        viewModel.updateServerUrl(server.address)
                                    } label: {
                                        HStack {
                                            Image(systemName: "server.rack")
                                                .foregroundColor(.accentColor)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(server.name)
                                                    .font(.subheadline).fontWeight(.medium)
                                                Text(server.address)
                                                    .font(.caption).foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption).foregroundColor(.secondary)
                                        }
                                        .padding(10)
                                        .background(.ultraThinMaterial)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Username
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Username").font(.caption).foregroundColor(.secondary)
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    // Password
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password").font(.caption).foregroundColor(.secondary)
                        SecureField("Password", text: $password)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                // Error
                if let errorMessage = viewModel.errorMessage, !showTestSuccess, !showTestFailure {
                    Text(errorMessage)
                        .foregroundColor(.red).font(.caption)
                        .multilineTextAlignment(.center)
                }

                // Login button
                Button {
                    viewModel.updateServerUrl(serverUrlLocal)
                    Task {
                        await viewModel.login(username: username, password: password, serverURL: trimmedServerUrl)
                        // Sync local field in case URL was changed by protocol fallback
                        serverUrlLocal = viewModel.serverUrl
                    }
                } label: {
                    HStack {
                        if viewModel.isLoading {
                            ProgressView().padding(.trailing, 4)
                        }
                        Text(viewModel.isLoading ? "Accesso in corso..." : "Accedi")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(username.isEmpty || password.isEmpty || viewModel.isLoading || !isServerUrlValid)
                .buttonStyle(.glassProminent)
                .controlSize(.large)

                Spacer().frame(height: 40)
            }
            .padding(24)
        }
        .background(Color(.systemBackground))
        .onAppear {
            if serverUrlLocal.isEmpty { serverUrlLocal = viewModel.serverUrl }
        }
        .alert(isPresented: $showingTestAlert) {
            Alert(
                title: Text("Connessione fallita"),
                message: Text(viewModel.errorMessage ?? "Impossibile raggiungere il server."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    #endif

    // MARK: - macOS Layout

    #if os(macOS)
    private var macOSBody: some View {
        VStack {
            Spacer()
            
            VStack(spacing: 0) {
                // App icon and title
                VStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: 40))
                        .foregroundStyle(.primary)
                    Text("amplifin")
                        .font(.largeTitle).fontWeight(.bold)
                    Text("Accedi al tuo server Jellyfin")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .padding(.bottom, 28)
                
                // Form fields
                VStack(spacing: 16) {
                    // Server URL field + test button
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL").font(.caption).foregroundColor(.secondary).padding(.leading, 2)
                        
                        HStack(spacing: 8) {
                            TextField("http://192.168.0.106:8096", text: $serverUrlLocal)
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .disableAutocorrection(true)
                                .textCase(.none)
                                .onChange(of: serverUrlLocal) {
                                    showTestSuccess = false
                                    showTestFailure = false
                                }
                                .onSubmit {
                                    viewModel.updateServerUrl(serverUrlLocal)
                                }
                            
                            Button {
                                viewModel.updateServerUrl(serverUrlLocal)
                                testConnection()
                            } label: {
                                if viewModel.isTestingConnection {
                                    ProgressView().scaleEffect(0.7).frame(width: 32, height: 32)
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .frame(width: 32, height: 32)
                                }
                            }
                            .disabled(trimmedServerUrl.isEmpty || viewModel.isTestingConnection)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .help("Testa la connessione al server")
                        }
                        
                        connectionStatus
                    }
                    
                    // Network discovery
                    VStack(alignment: .leading, spacing: 8) {
                        Button {
                            discoveryService.startDiscovery()
                        } label: {
                            HStack {
                                if discoveryService.isSearching {
                                    ProgressView().scaleEffect(0.7)
                                        .padding(.trailing, 4)
                                } else {
                                    Image(systemName: "magnifyingglass.circle")
                                }
                                Text(discoveryService.isSearching ? "Ricerca in corso..." : "Cerca server sulla rete")
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .disabled(discoveryService.isSearching)
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                        .help("Cerca server Jellyfin sulla rete locale")

                        if !discoveryService.discoveredServers.isEmpty {
                            VStack(spacing: 4) {
                                ForEach(discoveryService.discoveredServers) { server in
                                    Button {
                                        serverUrlLocal = server.address
                                        viewModel.updateServerUrl(server.address)
                                    } label: {
                                        HStack {
                                            Image(systemName: "server.rack")
                                                .foregroundColor(.accentColor)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(server.name)
                                                    .font(.subheadline).fontWeight(.medium)
                                                Text(server.address)
                                                    .font(.caption).foregroundColor(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption).foregroundColor(.secondary)
                                        }
                                        .padding(8)
                                        .background(.ultraThinMaterial)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    // Username
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Username").font(.caption).foregroundColor(.secondary).padding(.leading, 2)
                        TextField("Username", text: $username)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    
                    // Password
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Password").font(.caption).foregroundColor(.secondary).padding(.leading, 2)
                        SecureField("Password", text: $password)
                            .textFieldStyle(.plain)
                            .padding(10)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .frame(maxWidth: fieldMaxWidth)
                
                // Error message
                if let errorMessage = viewModel.errorMessage, !showTestSuccess, !showTestFailure {
                    Text(errorMessage)
                        .foregroundColor(.red).font(.caption)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: fieldMaxWidth)
                        .padding(.top, 8)
                }
                
                // Login button
                Button {
                    viewModel.updateServerUrl(serverUrlLocal)
                    Task {
                        await viewModel.login(username: username, password: password, serverURL: trimmedServerUrl)
                        // Sync local field in case URL was changed by protocol fallback
                        serverUrlLocal = viewModel.serverUrl
                    }
                } label: {
                    HStack {
                        if viewModel.isLoading {
                            ProgressView().scaleEffect(0.7).padding(.trailing, 4)
                        }
                        Text(viewModel.isLoading ? "Accesso in corso..." : "Accedi")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: fieldMaxWidth, minHeight: 36)
                }
                .disabled(username.isEmpty || password.isEmpty || viewModel.isLoading || !isServerUrlValid)
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .padding(.top, 24)
            }
            .padding(36)
            .glassEffect(in: .rect(cornerRadius: 24))
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if serverUrlLocal.isEmpty { serverUrlLocal = viewModel.serverUrl }
        }
        .alert(isPresented: $showingTestAlert) {
            Alert(
                title: Text("Connessione fallita"),
                message: Text(viewModel.errorMessage ?? "Impossibile raggiungere il server."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
    #endif

    // MARK: - Shared

    @ViewBuilder
    private var connectionStatus: some View {
        HStack(spacing: 6) {
            if showTestSuccess {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption2)
                Text("Connessione riuscita").font(.caption2).foregroundColor(.green)
            } else if showTestFailure {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.caption2)
                Text(viewModel.errorMessage ?? "Test fallito").font(.caption2).foregroundColor(.red).lineLimit(2)
            }
        }
        .frame(height: 16)
    }

    private func testConnection() {
        Task {
            showTestSuccess = false
            showTestFailure = false
            showingTestAlert = false
            
            let serverToTest = trimmedServerUrl
            let validFormat = serverToTest.lowercased().hasPrefix("http://") || serverToTest.lowercased().hasPrefix("https://")
            if !serverToTest.isEmpty && validFormat {
                let ok = await viewModel.testServerConnection(serverURL: serverToTest)
                if ok {
                    // Sync local field in case the URL was changed by fallback (https→http)
                    serverUrlLocal = viewModel.serverUrl
                    showTestSuccess = true
                    showTestFailure = false
                } else {
                    showTestSuccess = false
                    showTestFailure = true
                    showingTestAlert = true
                }
            } else {
                viewModel.errorMessage = "Inserisci un URL che inizi con http:// o https://"
                showTestSuccess = false
                showTestFailure = true
                showingTestAlert = true
            }
        }
    }
}
