import JadeAPI

/// Servicio `catalog` (también dummyjson.com: un servicio es un nombre lógico, no un host distinto).
///
/// A nivel de protocolo: un header fijo para todo el repositorio, los errores del servidor se
/// convierten en `CatalogError`, y hay dos intentos para fallos transitorios (5xx, red).
@Repository(service: "catalog")
@Headers(["X-Client": "JadeAPI-Guide"])
@ErrorTransform(CatalogErrorMapper.self)
@Retries(2, backoff: .constant(.milliseconds(300)))
public protocol CatalogRepository: Sendable {
    /// GET /products?limit=6 → `{"products": [...], "total": …}`. `@Unwrap` se queda con `products`,
    /// `@Transform` convierte DTOs en `Product`, `@CacheFor` evita repetir la petición durante 30 s.
    @Logged
    @Unwrap("products")
    @Transform(ProductsMapper.self)
    @CacheFor(.seconds(30))
    @Api("/products")
    func featured(limit: Int) async throws -> [Product]

    /// GET /products/category-list → `["beauty", "fragrances", …]`.
    @Logged
    @Api("/products/category-list")
    func categories() async throws -> [String]

    /// GET /products/:id. Llamadas simultáneas al mismo id comparten una petición; timeout de 5 s.
    @Transform(ProductMapper.self)
    @SingleFlight
    @Api("/products/:id", timeout: .seconds(5))
    func product(id: Int) async throws -> Product
}
