import JadeAPI
import JadeTesting

/// Raíz de composición: construye el entorno del ``Stage`` elegido y, a partir de él, los repositorios
/// y los stores. Lanza un error claro si la configuración no es válida, en vez de `try!`.
///
/// `try .live(in: environment)` resuelve cada repositorio con el servicio que declaró en `@Repository(service:)`.
@MainActor
public final class AppContainer {
    public let stage: Stage
    public let session: SessionStore
    public let catalog: CatalogStore
    public let wiki: WikiStore
    public let downloads: DownloadsStore
    public let echo: EchoStore

    /// - Parameter mock: servidor falso para el entorno `mock`; `nil` usa ``Fixtures`` con su latencia de demo.
    public init(stage: Stage, mock: MockClient? = nil) throws {
        self.stage = stage
        let tokens = SessionTokens()
        let environment = try AppEnvironment.make(stage: stage, tokens: tokens, mock: mock)

        let auth: AuthRepository = try .live(in: environment)
        let catalogRepository: CatalogRepository = try .live(in: environment)
        let wikiRepository: WikiRepository = try .live(in: environment)
        let photos: PhotosRepository = try .live(in: environment)
        let echoRepository: EchoRepository = try .live(in: environment)

        session = SessionStore(auth: auth, tokens: tokens)
        catalog = CatalogStore(catalog: catalogRepository, client: try environment.client(for: "catalog"))
        wiki = WikiStore(wiki: wikiRepository)
        downloads = DownloadsStore(photos: photos)
        echo = EchoStore(echo: echoRepository)
    }
}
