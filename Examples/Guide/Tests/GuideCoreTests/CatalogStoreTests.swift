import JadeAPI
import Testing
@testable import GuideCore

@MainActor
@Suite("Catálogo")
struct CatalogStoreTests {

    @Test("carga destacados y categorías a la vez, y el detalle de cada destacado")
    func load() async throws {
        let app = try TestApp()
        await app.run { await app.catalog.load() }
        #expect(app.catalog.errorMessage == nil)
        #expect(app.catalog.featured.map(\.name) == ["Essence Mascara", "Eyeshadow Palette", "Powder Canister"])
        #expect(app.catalog.featured.first?.price == 9.99)
        #expect(app.catalog.categories == ["beauty", "fragrances", "furniture"])
        #expect(app.catalog.details.count == 4)
    }

    @Test("el producto 9999 falla con CatalogError sin tumbar al resto")
    func missingProduct() async throws {
        let app = try TestApp()
        await app.run { await app.catalog.load() }
        guard case .failure(let error)? = app.catalog.details[9999] else { Issue.record("se esperaba un fallo para el 9999"); return }
        #expect(error as? CatalogError == .server(message: "Product with id '9999' not found"))
        #expect(app.catalog.details.filter { $0.key != 9999 }.allSatisfy { if case .success = $0.value { true } else { false } })
    }

    @Test("@Retries supera el 503 de la primera carga y @CacheFor evita la segunda petición")
    func retriesAndCache() async throws {
        let app = try TestApp()
        await app.run {
            await app.catalog.load()
            await app.catalog.load()
        }
        #expect(app.catalog.errorMessage == nil)
        #expect(app.mock.received.filter { $0.path == "/products" }.count == 2)   // 503 + reintento; luego caché
    }

    @Test("@Headers del repositorio viaja en cada petición del catálogo")
    func headers() async throws {
        let app = try TestApp()
        await app.run { await app.catalog.load() }
        #expect(app.mock.received.filter { $0.path.hasPrefix("/products") }.allSatisfy { $0.headers["X-Client"] == "JadeAPI-Guide" })
    }
}
