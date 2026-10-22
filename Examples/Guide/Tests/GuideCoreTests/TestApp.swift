import JadeTesting
@testable import GuideCore

/// Un contenedor en `mock` con fixtures sin latencia y sus propios logs, para que las pruebas
/// corran en paralelo sin compartir estado.
@MainActor
struct TestApp {
    let container: AppContainer
    let mock: MockClient
    let log = CallLog()
    let metrics = MetricsLog()

    init() throws {
        mock = Fixtures.makeClient(latency: .zero)
        container = try AppContainer(stage: .mock, mock: mock)
    }

    var session: SessionStore { container.session }
    var catalog: CatalogStore { container.catalog }

    /// Ejecuta `body` con estos logs como destino de `@Logged`, `RequestLogger` y `MetricsInterceptor`.
    func run(_ body: @MainActor () async -> Void) async {
        await CallLog.$current.withValue(log) {
            await MetricsLog.$current.withValue(metrics) { await body() }
        }
    }

    func signIn() async throws {
        await run { await session.signIn(username: "emilys", password: Fixtures.users["emilys"]!) }
        guard session.isSignedIn else { throw NotSignedIn() }
    }
    struct NotSignedIn: Error {}
}
