import JadeAPI
import Testing
@testable import GuideCore

@MainActor
@Suite("Sesión")
struct SessionStoreTests {

    @Test("login correcto deja la sesión iniciada con su perfil")
    func signIn() async throws {
        let app = try TestApp()
        try await app.signIn()
        guard case .signedIn(let profile) = app.session.status else { Issue.record("sin sesión"); return }
        #expect(profile.username == "emilys")
        #expect(profile.fullName == "Emilys Mock")
        #expect(app.session.errorMessage == nil)
    }

    @Test("credenciales inválidas: el 400 llega tal cual y la sesión sigue cerrada")
    func badCredentials() async throws {
        let app = try TestApp()
        await app.run { await app.session.signIn(username: "emilys", password: "otra") }
        #expect(app.session.status == .signedOut)
        #expect(app.session.errorMessage == "HTTP 400 en POST /auth/login")
    }

    @Test("el token lo pone AuthInterceptor: /auth/me sale con Bearer y el store nunca lo toca")
    func bearer() async throws {
        let app = try TestApp()
        try await app.signIn()
        let me = try #require(app.mock.received.first { $0.path == "/auth/me" })
        #expect(me.headers["Authorization"] == "Bearer tok-emilys")
    }

    @Test("logout olvida el token: la siguiente petición sale sin Bearer")
    func signOut() async throws {
        let app = try TestApp()
        try await app.signIn()
        await app.run { await app.session.signOut() }
        await app.run { await app.catalog.load() }
        #expect(app.session.status == .signedOut)
        let products = try #require(app.mock.received.last { $0.path == "/products" })
        #expect(products.headers["Authorization"] == nil)
    }

    @Test("@Logged deja rastro de cada llamada en el CallLog de la tarea")
    func loggedDecorator() async throws {
        let app = try TestApp()
        try await app.signIn()
        #expect(app.log.count(containing: "→ login(username:password:expiresInMins:)") == 1)
        #expect(app.log.count(containing: "← me() ok") == 1)
        #expect(CallLog.shared.entries.isEmpty, "la prueba no debe ensuciar el log compartido")
    }
}
