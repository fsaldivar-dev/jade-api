import Foundation
import JadeAPI
import Observation

/// Estado de la pantalla. Habla con los repositorios por su protocolo: cambiar de entorno
/// solo cambia el `AppClient` que reciben.
@MainActor
@Observable
final class SessionModel {
    var stage: Stage { didSet { rebuild() } }
    var user = "admin"
    var password = "admin"
    var token: Token?
    var profile: Profile?
    var error: String?
    var busy = false
    var log: [String] = []

    // Catálogo (fase 2)
    var featured: [Product] = []
    var categories: [String] = []
    var details: [Int: Result<Product, any Error>] = [:]
    var catalogError: String?
    var loadingCatalog = false

    private var auth: AuthRepository
    private var profiles: ProfileRepository
    private var catalog: CatalogRepository
    private var client: AppClient

    init(stage: Stage) {
        self.stage = stage
        let client = Self.makeClient(stage)
        self.client = client
        auth = AuthRepositoryClient(client: client)
        profiles = ProfileRepositoryClient(client: client)
        catalog = CatalogRepositoryClient(client: client)
    }

    /// Un solo cliente para toda la app: auth por interceptor y log con cURL redactado.
    private static func makeClient(_ stage: Stage) -> AppClient {
        AppClient(stage: stage, interceptors: [
            AuthInterceptor(tokens: SessionTokens.shared),
            RequestLogger(.line, sink: { Log.append($0) }),
        ])
    }

    private func rebuild() {
        client = Self.makeClient(stage)
        auth = AuthRepositoryClient(client: client)
        profiles = ProfileRepositoryClient(client: client)
        catalog = CatalogRepositoryClient(client: client)
        token = nil; profile = nil; error = nil
        featured = []; categories = []; details = [:]; catalogError = nil
        Task { await SessionTokens.shared.set(nil) }
    }

    /// Destacados y categorías a la vez (all), y luego el detalle de cada destacado en grupo con límite.
    func loadCatalog() async {
        loadingCatalog = true; catalogError = nil
        defer { loadingCatalog = false; log = Log.all }
        do {
            let repo = catalog
            let (featured, categories) = try await client.all(
                { try await repo.featured() },
                { try await repo.categories() }
            )
            self.featured = featured
            self.categories = categories
            let ids = featured.map(\.id) + [99]          // 99 no existe: se ve el error tipado sin tumbar al resto
            let results = await client.groupSettled(maxConcurrent: 2) { group in
                for id in ids { group.add { try await repo.product(id: id) } }
            }
            details = Dictionary(uniqueKeysWithValues: zip(ids, results))
        } catch {
            catalogError = "\(error)"
        }
    }

    func login() async {
        busy = true; defer { busy = false; log = Log.all }
        do {
            let token = try await auth.login(user: user, password: password)
            self.token = token
            await SessionTokens.shared.set(token.value)
            self.profile = try await profiles.me(token: Header(token.value))
            error = nil
            await loadCatalog()
        } catch let failure as HTTPError {
            error = failure.description
        } catch {
            self.error = "\(error)"
        }
    }

    func logout() async {
        guard let token else { return }
        busy = true; defer { busy = false; log = Log.all }
        try? await auth.logout(token: Header(token.value))
        await SessionTokens.shared.set(nil)
        self.token = nil; profile = nil
        featured = []; categories = []; details = [:]
    }
}
