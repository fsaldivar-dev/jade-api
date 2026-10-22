import Foundation
import JadeAPI

// MARK: - Dominio y DTO

struct ProductDTO: Decodable { let id: Int; let title: String; let price_cents: Int }
struct Product: Identifiable, Sendable, Equatable { let id: Int; let name: String; let price: Decimal }

/// DTO → dominio. El compilador verifica que `Input` es lo decodificado y `Output` el retorno.
struct ProductMapper: Transformer {
    func transform(_ dto: ProductDTO) throws -> Product {
        Product(id: dto.id, name: dto.title, price: Decimal(dto.price_cents) / 100)
    }
}
struct ProductsMapper: Transformer {
    func transform(_ dtos: [ProductDTO]) throws -> [Product] { try dtos.map(ProductMapper().transform) }
}

struct APIErrorBody: Decodable { let code: String; let message: String }
enum CatalogError: Error, CustomStringConvertible { case api(code: String, message: String)
    var description: String { if case .api(let code, let message) = self { return "\(code): \(message)" }; return "" }
}
struct CatalogErrorMapper: Transformer {
    func transform(_ body: APIErrorBody) throws -> CatalogError { .api(code: body.code, message: body.message) }
}

// MARK: - Repositorio: fase 2 completa en un protocolo

@Repository(service: "catalog")
@Unwrap("data")                              // todas las respuestas vienen como {data: …}
@ErrorTransform(CatalogErrorMapper.self)     // los errores del servidor se vuelven CatalogError
@Retries(2, backoff: .constant(.milliseconds(200)))
protocol CatalogRepository: Sendable {
    @Logged
    @Transform(ProductsMapper.self)
    @CacheFor(.seconds(30))                  // segunda carga sin red durante 30 s
    @Api("/catalog/featured")
    func featured() async throws -> [Product]

    @Logged
    @Api("/catalog/categories")
    func categories() async throws -> [String]

    @Transform(ProductMapper.self)
    @SingleFlight
    @Api("/catalog/:id", timeout: .seconds(2))
    func product(id: Int) async throws -> Product
}

// MARK: - Token de la sesión para AuthInterceptor

/// Guarda el token tras el login; el interceptor lo inyecta y, si el servidor devuelve 401, "refresca".
actor SessionTokens: TokenProvider {
    static let shared = SessionTokens()
    private var token: String?
    func set(_ token: String?) { self.token = token }
    func currentToken() async throws -> String? { token }
    func refreshToken() async throws -> String {
        guard let token else { throw CatalogError.api(code: "NO_SESSION", message: "inicia sesión") }
        return token   // en una app real: pedir uno nuevo al servidor
    }
}
