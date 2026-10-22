import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Repositorios contra MockClient")
struct RepositoryTests {

    let mock = MockClient()
    var client: AppClient { AppClient(baseURL: "https://api.ejemplo.com/v1", transport: mock) }
    var users: UsersRepository { UsersRepositoryClient(client: client) }
    var auth: AuthRepository { AuthRepositoryClient(client: client) }

    @Test("Ruta explícita con parámetro de path")
    func pathParameter() async throws {
        mock.on(.get, "/users/:id") { request in
            .json(#"{"id": 7, "name": "Paco"}"#)
        }
        #expect(try await users.user(id: 7) == User(id: 7, name: "Paco"))
        let request = try #require(mock.received.first)
        #expect(request.method == .get)
        #expect(request.path == "/users/7")
        #expect(request.url.absoluteString == "https://api.ejemplo.com/v1/users/7")
        #expect(request.endpoint == "user(id:)")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.body == nil)
    }

    @Test("Inferencia: getUser(id:) → GET /user?id=")
    func inferredGet() async throws {
        mock.on(.get, "/user") { _ in .json(#"{"id": 1, "name": "Ana"}"#) }
        #expect(try await users.getUser(id: 1).name == "Ana")
        #expect(mock.received.first?.url.query == "id=1")
    }

    @Test("Query: nil se omite y Query<T> fuerza query")
    func query() async throws {
        mock.on(.get, "/users/search") { _ in .json("[]") }
        _ = try await users.search(q: "pa co", page: nil, limit: 20)
        let url = try #require(mock.received.first?.url)
        #expect(url.query == "q=pa%20co&limit=20")
    }

    @Test("POST explícito: parámetros sueltos → campos del body JSON")
    func postFields() async throws {
        mock.on(.post, "/auth") { request in
            let body = try JSONDecoder().decode(Credentials.self, from: request.body ?? Data())
            return body == Credentials(user: "paco", password: "secreto") ? .json(#"{"value": "t0k"}"#) : .status(401)
        }
        #expect(try await auth.auth(user: "paco", password: "secreto") == Token(value: "t0k"))
        #expect(mock.received.first?.headers["Content-Type"] == "application/json")
    }

    @Test("Body<T> envía el valor completo")
    func bodyValue() async throws {
        mock.on(.post, "/auth/login") { request in
            let body = try JSONDecoder().decode(Credentials.self, from: request.body ?? Data())
            return .json(#"{"value": "\#(body.user)"}"#)
        }
        #expect(try await auth.login(credentials: Body(Credentials(user: "ana", password: "x"))).value == "ana")
    }

    @Test("Inferencia de verbo: postRefresh → POST /refresh, createSession → POST /session")
    func inferredPost() async throws {
        mock.on(.post, "/refresh") { _ in .json(#"{"value": "r"}"#) }
        mock.on(.post, "/session") { _ in .json(#"{"value": "s"}"#) }
        #expect(try await auth.postRefresh(token: "abc").value == "r")
        #expect(try await auth.createSession().value == "s")
        #expect(String(data: mock.received[0].body ?? Data(), encoding: .utf8) == #"{"token":"abc"}"#)
        #expect(mock.received[1].body == nil)
    }

    @Test("Header<T> va como header con el nombre de la etiqueta")
    func header() async throws {
        mock.on(.get, "/users/me") { request in
            request.headers["token"] == "Bearer x" ? .json(#"{"id": 9, "name": "Yo"}"#) : .status(401)
        }
        #expect(try await users.me(token: "Bearer x").id == 9)
    }

    @Test("Retornos Void, Data, String y Response")
    func returnKinds() async throws {
        mock.on(.delete, "/user") { _ in .noContent }
        mock.on(.get, "/users/:id/avatar") { _ in MockResponse(body: Data([1, 2, 3])) }
        mock.on(.get, "/users/:id/bio") { _ in MockResponse(body: Data("hola".utf8)) }
        mock.on(.get, "/users/:id/raw") { _ in MockResponse(status: 201, headers: ["X-Trace": "abc"], body: Data("raw".utf8)) }

        try await users.deleteUser(id: 3)
        #expect(mock.received.last?.method == .delete)
        #expect(try await users.avatar(id: 3) == Data([1, 2, 3]))
        #expect(try await users.bio(id: 3) == "hola")
        let response = try await users.raw(id: 3)
        #expect(response.status == 201)
        #expect(response.header("x-trace") == "abc")
        #expect(response.text == "raw")
    }

    @Test("Un decorador apilado en el protocolo se aplica: @Retry(3) reintenta")
    func decoratorCopiedFromProtocol() async throws {
        let counter = Counter()
        mock.on(.get, "/users/:id/flaky") { _ in
            counter.increment() < 3 ? .status(503) : .json(#"{"id": 5, "name": "Al tercero"}"#)
        }
        #expect(try await users.flaky(id: 5).name == "Al tercero")
        #expect(mock.received.count == 3)
    }

    @Test("@Decorate(Retry(3)) en el protocolo también se transcribe")
    func decorateFormCopiedFromProtocol() async throws {
        let counter = Counter()
        mock.on(.get, "/users/:id/flaky-inline") { _ in
            counter.increment() < 2 ? .status(503) : .json(#"{"id": 6, "name": "Al segundo"}"#)
        }
        #expect(try await users.flakyInline(id: 6).name == "Al segundo")
        #expect(mock.received.count == 2)
    }

    @Test("Errores tipados: status, decodificación y sin mock")
    func errors() async throws {
        mock.on(.get, "/users/:id") { request in
            request.path == "/users/404" ? .status(404, body: "no existe") : .json("not json")
        }
        await #expect(throws: HTTPError.self) { try await users.user(id: 404) }
        do { _ = try await users.user(id: 404) } catch let error as HTTPError {
            #expect(error.statusCode == 404)
            if case .status(_, let response) = error { #expect(response.text == "no existe") }
        }
        do { _ = try await users.user(id: 1) } catch let error as HTTPError {
            guard case .decoding = error else { Issue.record("esperaba .decoding, llegó \(error)"); return }
        }
        do { _ = try await users.getUser(id: 1) } catch let error as MockError {
            guard case .unmocked(let request) = error else { Issue.record("esperaba .unmocked"); return }
            #expect(request.path == "/user")
        }
    }

    @Test("La cancelación de la Task cancela la petición")
    func cancellation() async throws {
        mock.latency = .milliseconds(300)
        mock.on(.get, "/users/:id") { _ in .json(#"{"id": 1, "name": "x"}"#) }
        let repo = users
        let task = Task { try await repo.user(id: 1) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }
}

@Suite("Entornos")
struct StageTests {
    @Test("Resolución por argumento, variable de entorno y fallback")
    func resolve() {
        #expect(Stage.resolve(arguments: ["app", "--stage=dev"], environment: [:], fallback: .prod) == .dev)
        #expect(Stage.resolve(arguments: ["app"], environment: ["JADE_STAGE": "mock"], fallback: .prod) == .mock)
        #expect(Stage.resolve(arguments: ["app", "--stage=nope"], environment: [:], fallback: .prod) == .prod)
    }

    @Test("AppClient toma base y transporte del entorno")
    func clientFromStage() {
        let client = AppClient(stage: Stage.dev)
        #expect(client.baseURL.absoluteString == "https://dev.api.ejemplo.com/v1")
        #expect(client.transport is URLSessionClient)
    }

    @Test("La base con ruta se concatena sin duplicar barras")
    func basePath() throws {
        let client = AppClient(baseURL: URL(string: "https://api.ejemplo.com/v1/")!)
        let request = try client.makeRequest(Endpoint(name: "x", method: .get, path: "/users/:id", pathParameters: ["id": "a b"]))
        #expect(request.url.absoluteString == "https://api.ejemplo.com/v1/users/a%20b")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func increment() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
