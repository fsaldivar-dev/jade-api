import Foundation
import JadeAPI
import Testing

@Suite("Opciones de petición: reintentos, caché, single-flight, timeout")
struct OptionsTests {

    let mock = MockClient()
    var catalog: CatalogRepository {
        CatalogRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: mock))
    }

    @Test("@Retries del protocolo: 503 dos veces y luego 200 → tres peticiones y éxito")
    func retriesOnServerError() async throws {
        let counter = Counter()
        mock.on(.get, "/catalog/:id") { _ in counter.increment() < 3 ? .status(503) : .json(#"{"id": 1, "name": "ok"}"#) }
        #expect(try await catalog.item(id: 1).name == "ok")
        #expect(mock.received.count == 3)
    }

    @Test("No se reintenta un 404 ni un error de decodificación")
    func noRetryOnClientError() async throws {
        mock.on(.get, "/catalog/:id") { _ in .status(404) }
        await #expect(throws: HTTPError.self) { try await catalog.item(id: 2) }
        #expect(mock.received.count == 1)
        mock.reset()
        mock.on(.get, "/catalog/:id") { _ in .json("no json") }
        await #expect(throws: HTTPError.self) { try await catalog.item(id: 3) }
        #expect(mock.received.count == 1)
    }

    @Test("@Retries(1) en el endpoint anula los reintentos del protocolo")
    func endpointOverridesProtocol() async throws {
        mock.on(.get, "/catalog/no-retry") { _ in .status(503) }
        await #expect(throws: HTTPError.self) { try await catalog.noRetry() }
        #expect(mock.received.count == 1)
    }

    @Test("Retry-After se respeta por encima del backoff")
    func retryAfter() async throws {
        let counter = Counter()
        mock.on(.get, "/catalog/:id") { _ in
            counter.increment() == 1 ? MockResponse(status: 429, headers: ["Retry-After": "0.15"]) : .json(#"{"id": 1, "name": "ok"}"#)
        }
        let start = ContinuousClock.now
        _ = try await catalog.item(id: 9)
        #expect(ContinuousClock.now - start >= .milliseconds(140))
        #expect(mock.received.count == 2)
    }

    @Test("@CacheFor: la segunda llamada no llega al transporte")
    func cache() async throws {
        mock.on(.get, "/catalog") { _ in .json(#"[{"id": 1, "name": "a"}]"#) }
        let repo = catalog
        #expect(try await repo.catalog().count == 1)
        #expect(try await repo.catalog().count == 1)
        #expect(mock.received.count == 1)
    }

    @Test("La caché es por cliente: otro AppClient no la comparte")
    func cachePerClient() async throws {
        mock.on(.get, "/catalog") { _ in .json("[]") }
        _ = try await catalog.catalog()
        _ = try await catalog.catalog()        // `catalog` es computada: cliente nuevo cada vez
        #expect(mock.received.count == 2)
    }

    @Test("@SingleFlight: cinco llamadas simultáneas, una petición")
    func singleFlight() async throws {
        mock.latency = .milliseconds(80)
        mock.on(.get, "/catalog/featured") { _ in .json(#"[{"id": 1, "name": "f"}]"#) }
        let repo = catalog
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 1...5 { group.addTask { try await repo.featured().count } }
            for try await count in group { #expect(count == 1) }
        }
        #expect(mock.received.count == 1)
    }

    @Test("timeout de @Api: el transporte tarda más, falla con HTTPError.timeout y, por el @Retries del protocolo, se intenta tres veces")
    func timeout() async throws {
        mock.latency = .milliseconds(300)
        mock.on(.get, "/catalog/slow") { _ in .json("[]") }
        let start = ContinuousClock.now
        do { _ = try await catalog.slow(); Issue.record("debió expirar") }
        catch let error as HTTPError {
            guard case .timeout(let duration, let request) = error else { Issue.record("esperaba .timeout, llegó \(error)"); return }
            #expect(duration == .milliseconds(80))
            #expect(request.path == "/catalog/slow")
            #expect(request.timeout == 0.08)
        }
        #expect(mock.received.count == 3)                         // timeout es transitorio: reintenta
        #expect(ContinuousClock.now - start < .milliseconds(450)) // 3 × 80 ms + backoff, no 3 × 300 ms
    }

    @Test("Las opciones del cliente son la base; el endpoint gana campo a campo")
    func clientDefaults() async throws {
        var client = AppClient(baseURL: "https://api.ejemplo.com", transport: mock)
        client.options = RequestOptions(cache: .seconds(60))
        let request = try client.makeRequest(Endpoint(name: "x", method: .get, path: "/x", options: RequestOptions(timeout: .seconds(1))))
        #expect(request.options == RequestOptions(timeout: .seconds(1), cache: .seconds(60)))
    }
}
