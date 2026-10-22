import LoginCore
import SwiftUI

/// Formulario de acceso o, con sesión, el perfil y el catálogo.
struct SessionPanel: View {
    let session: SessionStore
    let catalog: CatalogStore

    var body: some View {
        switch session.status {
        case .signedOut, .signingIn:
            LoginForm(session: session)
        case .signedIn(let profile):
            ProfileHeader(profile: profile, session: session, catalog: catalog)
            CatalogView(catalog: catalog)
        }
        if let error = session.errorMessage {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

private struct LoginForm: View {
    let session: SessionStore
    @State private var user = "admin"
    @State private var password = "admin"

    private var isSigningIn: Bool { session.status == .signingIn }

    var body: some View {
        Form {
            TextField("Usuario", text: $user)
            SecureField("Contraseña", text: $password)
        }
        .formStyle(.grouped)
        Button(isSigningIn ? "Entrando…" : "Entrar") {
            Task { await session.signIn(user: user, password: password) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSigningIn)
        .keyboardShortcut(.defaultAction)
        Text("En mock la contraseña es el mismo usuario (admin/admin, viewer/viewer). En dev y prod no hay servidor: verás el error de red tipado.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}

private struct ProfileHeader: View {
    let profile: Profile
    let session: SessionStore
    let catalog: CatalogStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(profile.name, systemImage: "person.crop.circle.fill").font(.title2)
            Text("Rol: \(profile.role)").foregroundStyle(.secondary)
            HStack {
                Button("Cerrar sesión") {
                    Task {
                        await session.signOut()
                        catalog.clear()
                    }
                }
                Button(catalog.isLoading ? "Cargando…" : "Recargar catálogo") {
                    Task { await catalog.load() }
                }
                .disabled(catalog.isLoading)
            }
        }
        .task { await catalog.load() }   // al entrar, carga el catálogo una vez
    }
}
