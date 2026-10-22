import GuideCore
import SwiftUI

/// Formulario de acceso o, con sesión, el perfil. Al entrar carga el catálogo una vez.
struct SessionView: View {
    let session: SessionStore
    let catalog: CatalogStore
    @State private var username = "emilys"
    @State private var password = "emilyspass"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch session.status {
            case .signedOut, .signingIn:
                Form {
                    TextField("Usuario", text: $username)
                    SecureField("Contraseña", text: $password)
                }
                .formStyle(.grouped)
                Button(session.status == .signingIn ? "Entrando…" : "Entrar") {
                    Task { await session.signIn(username: username, password: password) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.status == .signingIn)
                .keyboardShortcut(.defaultAction)
                Text("Usuarios de dummyjson.com: emilys / emilyspass, michaelw / michaelwpass. Valen en live y en mock.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .signedIn(let profile):
                HStack(spacing: 12) {
                    AsyncImage(url: profile.image) { $0.resizable() } placeholder: { Color.gray.opacity(0.2) }
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                    VStack(alignment: .leading) {
                        Text(profile.fullName).font(.title2)
                        Text("@\(profile.username) · id \(profile.id)").foregroundStyle(.secondary)
                    }
                }
                Button("Cerrar sesión") {
                    Task {
                        await session.signOut()
                        catalog.clear()
                    }
                }
                .task { await catalog.load() }
                Text("El token lo puso AuthInterceptor en GET /auth/me: el store nunca lo tocó. Mira el log de la derecha.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let error = session.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(.top, 8)
    }
}
