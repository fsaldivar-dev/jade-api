import Foundation
import JadeAPI
import Testing

@Suite("Interceptores")
struct InterceptorTests {

    let mock = MockClient()

    func client(_ interceptors: [any Interceptor]) -> AppClient {
        AppClient(baseURL: "https://api.ejemplo.com", transport: mock, interceptors: interceptors)
    }

    @Test("Orden: el primero es el más externo; la petición llega al transporte con todos los cambios")
    func order() async throws {
        let log = TraceLog()
        mock.on(.get, "/users/:id") { _ in .json(#"{"id": 1, "name": "x"}"#) }
        let users: UsersRepository = UsersRepositoryClient(client: client([Trace(name: "A", log: log), Trace(name: "B", log: log)]))
        _ = try await users.user(id: 1)
        #expect(log.all == ["A →", "B →", "B ←", "A ←"])
        #expect(mock.received.first?.headers["X-Trace"] == "A,B")
    }

    @Test("RequestAdapter y ResponseInterceptor: atajos de una sola función")
    func adapters() async throws {
        struct Stamp: ResponseInterceptor {
            func process(_ response: Response) async throws -> Response {
                Response(status: response.status, headers: response.headers.merging(["X-Stamped": "yes"]) { a, _ in a }, body: response.body, request: response.request)
            }
        }
        mock.on(.get, "/users/:id/raw") { request in
            request.headers["X-App"] == "jade" ? MockResponse(body: Data("ok".utf8)) : .status(400)
        }
        let users: UsersRepository = UsersRepositoryClient(client: client([CommonHeaders(["X-App": "jade"]), Stamp()]))
        let response = try await users.raw(id: 1)
        #expect(response.text == "ok")
        #expect(response.header("X-Stamped") == "yes")
    }

    @Test("Auth: inyecta el token y, ante 401, refresca una vez y repite la petición")
    func authRefresh() async throws {
        let tokens = CountingTokens(token: "old")
        mock.on(.get, "/users/:id") { request in
            request.headers["Authorization"] == "Bearer fresh-1" ? .json(#"{"id": 1, "name": "ok"}"#) : .status(401)
        }
        let users: UsersRepository = UsersRepositoryClient(client: client([AuthInterceptor(tokens: tokens)]))
        #expect(try await users.user(id: 1).name == "ok")
        #expect(mock.received.count == 2)
        #expect(mock.received[0].headers["Authorization"] == "Bearer old")
        #expect(mock.received[1].headers["Authorization"] == "Bearer fresh-1")
        #expect(await tokens.refreshes == 1)
    }

    @Test("Auth: N peticiones simultáneas con 401 comparten un único refresh")
    func authSingleFlight() async throws {
        let tokens = CountingTokens(token: "old", refreshDelay: .milliseconds(100))
        mock.on(.get, "/users/:id") { request in
            request.headers["Authorization"]?.hasPrefix("Bearer fresh") == true ? .json(#"{"id": 1, "name": "ok"}"#) : .status(401)
        }
        let users: UsersRepository = UsersRepositoryClient(client: client([AuthInterceptor(tokens: tokens)]))
        try await withThrowingTaskGroup(of: User.self) { group in
            for id in 1...5 { group.addTask { try await users.user(id: id) } }
            for try await user in group { #expect(user.name == "ok") }
        }
        #expect(await tokens.refreshes == 1)
        #expect(mock.received.count == 10)   // 5 rechazadas + 5 repetidas
    }

    @Test("Auth: sin token no manda header; si el refresh falla, el error sube")
    func authFailures() async throws {
        let tokens = CountingTokens(token: nil)
        mock.on(.get, "/users/:id") { request in
            request.headers["Authorization"] == nil ? .json(#"{"id": 1, "name": "anon"}"#) : .status(401)
        }
        let users: UsersRepository = UsersRepositoryClient(client: client([AuthInterceptor(tokens: tokens)]))
        #expect(try await users.user(id: 1).name == "anon")

        struct Broken: TokenProvider {
            func currentToken() async throws -> String? { "x" }
            func refreshToken() async throws -> String { throw GuardFailure() }
        }
        struct GuardFailure: Error {}
        mock.reset()
        mock.on(.get, "/users/:id") { _ in .status(401) }
        let broken: UsersRepository = UsersRepositoryClient(client: client([AuthInterceptor(tokens: Broken())]))
        await #expect(throws: GuardFailure.self) { try await broken.user(id: 1) }
    }

    @Test("RequestLogger: redacta Authorization y registra respuesta y error")
    func logger() async throws {
        final class Lines: @unchecked Sendable { let lock = NSLock(); var all: [String] = []; func add(_ s: String) { lock.lock(); all.append(s); lock.unlock() } }
        let lines = Lines()
        mock.on(.get, "/users/:id") { request in request.path == "/users/1" ? .json(#"{"id": 1, "name": "x"}"#) : .status(500) }
        let users: UsersRepository = UsersRepositoryClient(client: client([
            CommonHeaders(["Authorization": "Bearer secreto"]),
            RequestLogger(.curl, sink: { lines.add($0) }),
        ]))
        _ = try await users.user(id: 1)
        _ = try? await users.user(id: 2)
        let joined = lines.all.joined(separator: "\n")
        #expect(joined.contains("curl -X GET"))
        #expect(joined.contains("Authorization: •••"))
        #expect(!joined.contains("secreto"))
        #expect(lines.all.contains { $0.hasPrefix("← 200 GET /users/1") })
        #expect(lines.all.contains { $0.hasPrefix("← 500 GET /users/2") })   // 500 no es error de transporte: se registra como respuesta
    }

    @Test("@Interceptors en el protocolo se añade por dentro de los del cliente")
    func repositoryInterceptors() async throws {
        let log = TraceLog()
        mock.on(.get, "/payments/:id") { _ in .noContent }
        let payments: PaymentsRepository = PaymentsRepositoryClient(client: client([Trace(name: "client", log: log)]))
        _ = try await payments.payment(id: 9)
        let request = try #require(mock.received.first)
        #expect(request.headers["X-Repo"] == "payments")
        #expect(request.headers["X-Trace"] == "client")
    }
}
