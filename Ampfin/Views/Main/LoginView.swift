import SwiftUI

struct LoginView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var username = ""
    @State private var password = ""
    @State private var serverUrlLocal = ""
    
    // Shared width for all fields so they align
    private let fieldMaxWidth: CGFloat = 420
    
    private var trimmedServerUrl: String {
        serverUrlLocal.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // URL ora è obbligatoria: deve essere non vuota e iniziare con http:// o https://
    private var isServerUrlValid: Bool {
        let t = trimmedServerUrl.lowercased()
        return !t.isEmpty && (t.hasPrefix("http://") || t.hasPrefix("https://"))
    }
    
    // Local UI feedback for inline result and alert
    @State private var showTestSuccess: Bool = false
    @State private var showTestFailure: Bool = false
    @State private var showingTestAlert: Bool = false
    
    var body: some View {
        VStack(spacing: 15) {
            Text("Accedi a Jellyfin")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Server URL (es. http://192.168.0.106:8096)", text: $serverUrlLocal)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(maxWidth: fieldMaxWidth)
                        .disableAutocorrection(true)
                        .textCase(.none)
                        .onChange(of: serverUrlLocal) { newValue in
                            // Persistiamo la URL su modifica (salvata in UserDefaults)
                            viewModel.updateServerUrl(newValue)
                            // reset feedback
                            showTestSuccess = false
                            showTestFailure = false
                        }
                    
                    Button(action: {
                        Task {
                            showTestSuccess = false
                            showTestFailure = false
                            showingTestAlert = false
                            
                            let serverToTest = trimmedServerUrl
                            let validFormat = serverToTest.lowercased().hasPrefix("http://") || serverToTest.lowercased().hasPrefix("https://")
                            if !serverToTest.isEmpty && validFormat {
                                let ok = await viewModel.testServerConnection(serverURL: serverToTest)
                                if ok {
                                    showTestSuccess = true
                                    showTestFailure = false
                                    // Non mostriamo alert per successo (solo inline)
                                } else {
                                    showTestSuccess = false
                                    showTestFailure = true
                                    // Mostriamo alert per il fallimento con dettagli
                                    showingTestAlert = true
                                }
                            } else {
                                viewModel.errorMessage = "Inserisci un URL che inizi con http:// o https:// per testare la connessione."
                                showTestSuccess = false
                                showTestFailure = true
                                showingTestAlert = true
                            }
                        }
                    }) {
                        if viewModel.isTestingConnection {
                            ProgressView()
                                .scaleEffect(0.8)
                                .frame(width: 90, height: 30)
                        } else {
                            Text("Test connection")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .frame(height: 30)
                        }
                    }
                    .disabled(trimmedServerUrl.isEmpty || viewModel.isTestingConnection)
                    .controlSize(.small)
                }
                
                // Inline feedback with new icons and smaller text
                HStack(spacing: 8) {
                    if showTestSuccess {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundColor(.green)
                            .font(.caption2)
                        Text("Connessione OK")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else if showTestFailure {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption2)
                        Text(viewModel.errorMessage ?? "Test fallito")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: fieldMaxWidth, alignment: .leading)
                    } else {
                        // no result yet — keep space consistent
                        Text(" ")
                            .font(.caption2)
                    }
                }
            }
            
            TextField("Username", text: $username)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(maxWidth: fieldMaxWidth)
            
            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(maxWidth: fieldMaxWidth)
            
            if let errorMessage = viewModel.errorMessage, !showTestSuccess {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: fieldMaxWidth)
            }
            
            Button("Login") {
                Task {
                    // Passiamo la serverUrl valida (obbligatoria)
                    let serverParam: String = trimmedServerUrl
                    await viewModel.login(username: username, password: password, serverURL: serverParam)
                }
            }
            .disabled(username.isEmpty || password.isEmpty || viewModel.isLoading || !isServerUrlValid)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: fieldMaxWidth)
            
            if viewModel.isLoading {
                ProgressView("Caricamento...")
            }
        }
        .padding()
        .onAppear {
            // Precompila il campo con la serverUrl corrente (salvata nel ViewModel / UserDefaults), se presente
            if serverUrlLocal.isEmpty {
                serverUrlLocal = viewModel.serverUrl
            }
        }
        // Alert modale mostrato solo in caso di fallimento del test
        .alert(isPresented: $showingTestAlert) {
            let message = viewModel.errorMessage ?? "Impossibile raggiungere il server."
            return Alert(
                title: Text("Connessione fallita"),
                message: Text(message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
