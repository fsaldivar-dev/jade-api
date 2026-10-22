import JadeTesting
@testable import LoginCore

/// Un contenedor en `mock` con fixtures sin latencia y su propio ``CallLog``, para que las pruebas
/// corran en paralelo sin compartir estado.
@MainActor
struct TestApp {
    let container: AppContainer
    let mock: MockClient
    let log = CallLog()

    init() throws {
        mock = Fixtures.makeClient(latency: .zero)
        container = try AppContainer(stage: .mock, mock: mock)
    }

    var session: SessionStore { container.session }
    var catalog: CatalogStore { container.catalog }

    /// Ejecuta `body` con este log como destino de `@Logged` y del `RequestLogger`.
    func run(_ body: @MainActor () async -> Void) async {
        await CallLog.$current.withValue(log) { await body() }
    }
}
