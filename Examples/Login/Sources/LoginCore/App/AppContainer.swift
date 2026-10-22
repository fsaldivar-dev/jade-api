import JadeAPI
import JadeTesting

/// Raíz de composición: construye el entorno del ``Stage`` elegido y, a partir de él, los repositorios
/// y los stores. Lanza un error claro si la configuración no es válida, en vez de `try!`.
@MainActor
public final class AppContainer {
    public let stage: Stage
    public let session: SessionStore
    public let catalog: CatalogStore

    /// - Parameter mock: servidor falso para el entorno `mock`; `nil` usa ``Fixtures`` con su latencia de demo.
    public init(stage: Stage, mock: MockClient? = nil) throws {
        self.stage = stage
        let tokens = SessionTokens()
        let environment = try AppEnvironment.make(stage: stage, tokens: tokens, mock: mock)

        let auth: AuthRepository = try .live(in: environment)
        let profiles: ProfileRepository = try .live(in: environment)
        let catalogRepository: CatalogRepository = try .live(in: environment)

        session = SessionStore(auth: auth, profiles: profiles, tokens: tokens)
        catalog = CatalogStore(catalog: catalogRepository, client: try environment.client(for: "catalog"))
    }
}
