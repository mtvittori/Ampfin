import SwiftUI

struct LoginView: View {
    @EnvironmentObject var viewModel: JellyfinViewModel
    @State private var username = ""
    @State private var password = ""
    
    var body: some View {
        VStack(spacing: 15) {
            Text("Accedi a Jellyfin").font(.largeTitle).fontWeight(.bold)
            
            TextField("Username", text: $username)
                .textFieldStyle(RoundedBorderTextFieldStyle()).frame(maxWidth: 300)
            
            SecureField("Password", text: $password)
                .textFieldStyle(RoundedBorderTextFieldStyle()).frame(maxWidth: 300)
            
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).foregroundColor(.red).font(.caption).multilineTextAlignment(.center)
            }
            
            Button("Login") {
                Task {
                    await viewModel.login(username: username, password: password)
                }
            }
            .disabled(username.isEmpty || password.isEmpty || viewModel.isLoading)
            .buttonStyle(.borderedProminent).controlSize(.large)
            
            if viewModel.isLoading {
                ProgressView("Caricamento...")
            }
        }
    }
}
