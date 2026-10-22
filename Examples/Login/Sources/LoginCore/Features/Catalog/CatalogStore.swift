import JadeAPI
import Observation

/// Estado del catálogo: destacados y categorías a la vez (`all`), y el detalle de cada destacado en un
/// grupo con límite (`groupSettled`), donde un producto inexistente falla sin tumbar al resto.
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
    /// Id que no existe en el servidor, para mostrar el error tipado (`CatalogError`) en pantalla.
    private let missingProductID = 99

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
                { try await repo.featured() },
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
            errorMessage = SessionStore.describe(error)
        }
    }

    public func clear() {
        featured = []
        categories = []
        details = [:]
        errorMessage = nil
    }

    /// Detalles ordenados por id, para listarlos.
    public var sortedDetails: [(id: Int, result: Result<Product, any Error>)] {
        details.keys.sorted().compactMap { id in details[id].map { (id, $0) } }
    }
}
