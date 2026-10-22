import JadeAPI

/// Servicio `catalog`. A nivel de protocolo: todas las respuestas vienen como `{data: …}`, los errores
/// del servidor se convierten en `CatalogError`, y hay dos intentos para fallos transitorios.
@Repository(service: "catalog")
@Unwrap("data")
@ErrorTransform(CatalogErrorMapper.self)
@Retries(2, backoff: .constant(.milliseconds(200)))
public protocol CatalogRepository: Sendable {
    /// Destacados, en caché 30 s: la segunda carga no toca la red.
    @Logged
    @Transform(ProductsMapper.self)
    @CacheFor(.seconds(30))
    @Api("/catalog/featured")
    func featured() async throws -> [Product]

    @Logged
    @Api("/catalog/categories")
    func categories() async throws -> [String]

    /// Detalle. Llamadas simultáneas al mismo id comparten una petición; timeout de 2 s.
    @Transform(ProductMapper.self)
    @SingleFlight
    @Api("/catalog/:id", timeout: .seconds(2))
    func product(id: Int) async throws -> Product
}
