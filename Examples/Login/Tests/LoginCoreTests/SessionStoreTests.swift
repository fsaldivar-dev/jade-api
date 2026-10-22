import JadeAPI
import JadeTesting
import Testing
@testable import LoginCore

@MainActor
@Suite("Sesión")
struct SessionStoreTests {

    @Test("login correcto deja la sesión iniciada con su perfil")
    func signIn() async throws {
        let app = try TestApp()
        await app.run { await app.session.signIn(user: "admin", password: "admin") }

        #expect(app.session.status == .signedIn(Profile(id: 1, name: "Admin", role: "admin")))
        #expect(app.session.token?.value == "tok-admin")
        #expect(app.session.errorMessage == nil)
    }

    @Test("credenciales inválidas: el 401 llega tal cual y la sesión sigue cerrada")
    func badCredentials() async throws {
        let app = try TestApp()
        await app.run { await app.session.signIn(user: "admin", password: "otra") }

        #expect(app.session.status == .signedOut)
        #expect(app.session.token == nil)
        #expect(app.session.errorMessage == "HTTP 401 en POST /auth")
    }

    @Test("logout limpia token y perfil")
    func signOut() async throws {
        let app = try TestApp()
        await app.run {
            await app.session.signIn(user: "viewer", password: "viewer")
            await app.session.signOut()
        }

        #expect(app.session.status == .signedOut)
        #expect(app.session.token == nil)
        #expect(app.log.count(containing: "← logout(token:) ok") == 1)
    }

    @Test("@Logged deja rastro de cada llamada en el CallLog de la tarea")
    func loggedDecorator() async throws {
        let app = try TestApp()
        await app.run { await app.session.signIn(user: "admin", password: "admin") }

        #expect(app.log.count(containing: "→ login(user:password:)") == 1)
        #expect(app.log.count(containing: "← login(user:password:) ok") == 1)
        #expect(app.log.count(containing: "← me(token:) ok") == 1)
        #expect(CallLog.shared.entries.isEmpty, "la prueba no debe ensuciar el log compartido")
    }
}
