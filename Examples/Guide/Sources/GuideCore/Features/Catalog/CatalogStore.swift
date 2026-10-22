import JadeAPI
import Observation

/// Pestaña Catálogo: destacados y categorías a la vez, y el detalle de cada destacado en grupo.
///
/// Qué enseña: `client.all` para lanzar dos peticiones distintas y esperar las dos; `groupSettled`
/// para N peticiones iguales con límite de concurrencia donde una puede fallar sin tumbar al resto
/// (el producto 9999 no existe: su fila muestra el `CatalogError` tipado); y en el repositorio
/// `@Unwrap`, `@Transform`, `@ErrorTransform`, `@Retries`, `@CacheFor`, `@SingleFlight`.
@MainActor
@Observable
public final class CatalogStore {
    public private(set) var featured: [Product] = []
    public private(set) var categories: [String] = []
    public private(set) var details: [Int: Result<Product, any Error>] = [:]
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    private let catalog: any CatalogRepository
    private let client: AppClient
    /// Id que no existe en el servidor, para mostrar el error tipado en pantalla.
    private let missingProductID = 9999

    public init(catalog: any CatalogRepository, client: AppClient) {
        self.catalog = catalog
        self.client = client
    }

    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let repo = catalog
            let (featured, categories) = try await client.all(
                { try await repo.featured(limit: 6) },
                { try await repo.categories() }
            )
            self.featured = featured
            self.categories = categories

            let ids = featured.map(\.id) + [missingProductID]
            let results = await client.groupSettled(maxConcurrent: 2) { group in
                for id in ids { group.add { try await repo.product(id: id) } }
            }
            details = Dictionary(uniqueKeysWithValues: zip(ids, results))
        } catch {
            errorMessage = describe(error)
        }
    }

    public private(set) var searchResults: [Product] = []

    /// Busca con un `ProductQuery` (@ApiRequest): el store no arma parámetros sueltos, pasa el objeto.
    public func search(_ text: String) async {
        guard !text.isEmpty else { searchResults = []; return }
        do {
            searchResults = try await catalog.search(ProductQuery(q: text, limit: 10))
        } catch {
            errorMessage = describe(error)
        }
    }

    public func clear() {
        featured = []
        categories = []
        details = [:]
        searchResults = []
        errorMessage = nil
    }

    /// Detalles ordenados por id, para listarlos.
    public var sortedDetails: [(id: Int, result: Result<Product, any Error>)] {
        details.keys.sorted().compactMap { id in details[id].map { (id, $0) } }
    }
}
