import JadeAPI
import JadeTesting
import Testing
@testable import LoginCore

@MainActor
@Suite("Catálogo")
struct CatalogStoreTests {

    private func makeSignedInApp() async throws -> TestApp {
        let app = try TestApp()
        await app.run { await app.session.signIn(user: "admin", password: "admin") }
        try #require(app.session.isSignedIn)
        return app
    }

    @Test("carga destacados y categorías a la vez, y el detalle de cada destacado")
    func load() async throws {
        let app = try await makeSignedInApp()
        await app.run { await app.catalog.load() }

        #expect(app.catalog.errorMessage == nil)
        #expect(app.catalog.featured.map(\.name) == ["Tornillo M4", "Tuerca M4", "Arandela"])
        #expect(app.catalog.featured.first?.price == 12.50)   // price_cents → Decimal
        #expect(app.catalog.categories == ["Fijación", "Herramienta", "Pintura"])
        #expect(app.catalog.details.count == 4)
    }

    @Test("el producto 99 falla con CatalogError sin tumbar al resto")
    func missingProduct() async throws {
        let app = try await makeSignedInApp()
        await app.run { await app.catalog.load() }

        guard case .failure(let error)? = app.catalog.details[99] else {
            Issue.record("se esperaba un fallo para el producto 99"); return
        }
        #expect(error as? CatalogError == .api(code: "NOT_FOUND", message: "el producto 99 no existe"))
        let others = app.catalog.details.filter { $0.key != 99 }
        #expect(others.count == 3)
        #expect(others.allSatisfy { if case .success = $0.value { true } else { false } })
    }

    @Test("sin sesión el catálogo responde 401")
    func requiresSession() async throws {
        let app = try TestApp()
        await app.run { await app.catalog.load() }

        #expect(app.catalog.featured.isEmpty)
        #expect(app.catalog.errorMessage == "HTTP 401 en GET /catalog/featured")
    }

    @Test("@Retries supera el 503 de la primera carga y @CacheFor evita la segunda petición")
    func retriesAndCache() async throws {
        let app = try await makeSignedInApp()
        await app.run {
            await app.catalog.load()
            await app.catalog.load()
        }

        #expect(app.catalog.errorMessage == nil)
        // 503 + reintento en la primera carga; la segunda sale de caché: solo dos peticiones reales.
        #expect(app.mock.received.filter { $0.path.hasSuffix("/catalog/featured") }.count == 2)
    }
}
