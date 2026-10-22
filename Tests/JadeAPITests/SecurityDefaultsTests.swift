import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Nivel 1: defaults seguros")
struct SecurityDefaultsTests {

    let mock = MockClient()

    @Test("http:// se rechaza cuando la política no lo permite (release) y se acepta en Debug")
    func insecureURL() throws {
        var client = AppClient(baseURL: "http://localhost:8080", transport: mock)
        #expect(SecurityPolicy.isDebugBuild)                       // los tests corren en Debug
        _ = try client.makeRequest(Endpoint(name: "x", method: .get, path: "/x"))

        client.security = SecurityPolicy(allowsInsecureHTTP: false)  // lo que vale en release
        #expect(throws: HTTPError.self) { try client.makeRequest(Endpoint(name: "x", method: .get, path: "/x")) }
        do { _ = try client.makeRequest(Endpoint(name: "x", method: .get, path: "/x")) } catch let error as HTTPError {
            guard case .insecureURL(let url) = error else { Issue.record("esperaba .insecureURL"); return }
            #expect(url.host == "localhost")
        }
        let secure = AppClient(baseURL: "https://api.ejemplo.com", transport: mock)
        _ = try secure.makeRequest(Endpoint(name: "x", method: .get, path: "/x"))
    }

    @Test("@Idempotent manda una Idempotency-Key distinta por llamada y la misma en los reintentos")
    func idempotentRetry() async throws {
        let counter = Counter()
        mock.on(.post, "/orders") { _ in counter.increment() < 2 ? .status(503) : .json(#"{"id": 1, "name": "ok"}"#) }
        let orders: OrdersRepository = OrdersRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: mock))
        _ = try await orders.place(order: "a")
        #expect(mock.received.count == 2)
        let keys = mock.received.compactMap { $0.headers["Idempotency-Key"] }
        #expect(keys.count == 2)
        #expect(keys[0] == keys[1])                                    // misma clave en el reintento
        _ = try await orders.place(order: "b")
        #expect(mock.received[2].headers["Idempotency-Key"] != keys[0]) // clave nueva en otra llamada
    }

    @Test("Un POST sin Idempotency-Key no se reintenta aunque la política lo pida (defensa en runtime)")
    func runtimeRefusesUnsafeRetry() async throws {
        mock.on(.post, "/raw") { _ in .status(503) }
        let client = AppClient(baseURL: "https://api.ejemplo.com", transport: mock)
        let endpoint = Endpoint(name: "raw", method: .post, path: "/raw", options: RequestOptions(retry: RetryPolicy(attempts: 3)))
        await #expect(throws: HTTPError.self) { try await client.performResponse(endpoint) }
        #expect(mock.received.count == 1)

        let get = Endpoint(name: "get", method: .get, path: "/raw", options: RequestOptions(retry: RetryPolicy(attempts: 3)))
        mock.on(.get, "/raw") { _ in .status(503) }
        await #expect(throws: HTTPError.self) { try await client.performResponse(get) }
        #expect(mock.received.count == 4)
    }

    @Test("El logger redacta headers, query y body sensibles")
    func loggerRedaction() async throws {
        final class Lines: @unchecked Sendable { let lock = NSLock(); var all: [String] = []; func add(_ s: String) { lock.lock(); all.append(s); lock.unlock() } }
        let lines = Lines()
        mock.on(.post, "/auth") { _ in .json(#"{"value": "t"}"#) }
        let client = AppClient(baseURL: "https://api.ejemplo.com", transport: mock, interceptors: [RequestLogger(.curl, sink: { lines.add($0) })])
        let endpoint = Endpoint(name: "auth", method: .post, path: "/auth",
                                query: [("otp", "123456"), ("page", "2")],
                                headers: ["X-Api-Key": "sk_live_abc"],
                                body: .fields([("user", "paco"), ("password", "secreto")]))
        _ = try await client.performResponse(endpoint)
        let joined = lines.all.joined(separator: "\n")
        #expect(!joined.contains("sk_live_abc"))
        #expect(!joined.contains("secreto"))
        #expect(!joined.contains("123456"))
        #expect(joined.contains("page=2"))
        #expect(joined.contains(#""user":"paco""#))
        #expect(joined.contains("•••"))
    }

    @Test("La política marca como sensibles credenciales y datos de tarjeta, sin importar mayúsculas")
    func sensitiveKeys() {
        let policy = SecurityPolicy.default
        for key in ["Authorization", "X-API-KEY", "password", "CVV", "refresh_token"] { #expect(policy.isSensitive(key)) }
        for key in ["Accept", "page", "user", "Content-Type"] { #expect(!policy.isSensitive(key)) }
    }
}
