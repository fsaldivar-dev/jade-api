import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Atributos de repositorio: @BaseURL, @Headers, @KeyMapping")
struct RepositoryAttributesTests {

    let mock = MockClient()
    var client: AppClient { AppClient(baseURL: URL(string: "https://api.ejemplo.com")!, transport: mock, headers: ["Accept": "application/json", "X-Client": "cliente"]) }
    var accounts: AccountsRepository { AccountsRepositoryClient(client: client) }

    @Test("@BaseURL con prefijo: la ruta cuelga de base + prefijo; el mock sigue viendo la ruta del endpoint")
    func basePrefix() async throws {
        mock.on(.get, "/accounts/:id") { _ in .json(#"{"id": 7, "full_name": "Paco", "created_at": "2026-10-22T10:00:00Z"}"#) }
        _ = try await accounts.account(id: 7)
        let request = try #require(mock.received.first)
        #expect(request.url.absoluteString == "https://api.ejemplo.com/v2/accounts/7")
        #expect(request.path == "/accounts/7")
    }

    @Test("@BaseURL con URL completa sustituye la base del cliente")
    func baseAbsolute() async throws {
        mock.on(.get, "/ping") { _ in MockResponse(body: Data("pong".utf8)) }
        let legacy: LegacyRepository = LegacyRepositoryClient(client: client)
        #expect(try await legacy.ping() == "pong")
        #expect(mock.received.first?.url.absoluteString == "https://legacy.ejemplo.com/api/ping")
    }

    @Test("@Headers: los del repositorio ganan a los del cliente, los del requisito solo van en el suyo")
    func headers() async throws {
        mock.on(.get, "/accounts/:id") { _ in .json(#"{"id": 1, "full_name": "A", "created_at": "2026-01-01T00:00:00Z"}"#) }
        mock.on(.post, "/accounts") { _ in .json(#"{"id": 2, "full_name": "B", "created_at": "2026-01-01T00:00:00Z"}"#) }
        _ = try await accounts.account(id: 1)
        _ = try await accounts.create(fullName: "B")
        let get = try #require(mock.received.first)
        let post = try #require(mock.received.last)
        #expect(get.headers["X-Client"] == "ios")
        #expect(get.headers["Accept-Language"] == "es-MX")
        #expect(get.headers["Accept"] == "application/json")
        #expect(get.headers["X-Trace"] == nil)
        #expect(post.headers["X-Trace"] == "create")
        #expect(post.headers["X-Client"] == "ios")
    }

    @Test("@KeyMapping(.snakeCase, dates: .iso8601): decodifica y codifica sin tocar el decoder del cliente")
    func keyMapping() async throws {
        mock.on(.post, "/accounts") { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            guard body.contains(#""full_name":"Paco""#) else { return .status(400, body: body) }
            return .json(#"{"id": 9, "full_name": "Paco", "created_at": "2026-10-22T10:00:00Z"}"#)
        }
        let account = try await accounts.create(fullName: "Paco")
        #expect(account.fullName == "Paco")
        #expect(account.createdAt == Date(timeIntervalSince1970: 1_792_663_200))
        // El cliente original no cambió: sigue con claves tal cual, así que `full_name` no llega a `fullName`.
        struct Probe: Decodable { let fullName: String? }
        #expect(try client.decoder.decode(Probe.self, from: Data(#"{"full_name": "x"}"#.utf8)).fullName == nil)
    }

    @Test("with(base:) respeta una base con ruta y barra final")
    func withBase() {
        let base = AppClient(baseURL: "https://api.ejemplo.com/root/")
        #expect(base.with(base: "/v2").baseURL.absoluteString == "https://api.ejemplo.com/root/v2")
        #expect(base.with(base: "/v2/admin").baseURL.absoluteString == "https://api.ejemplo.com/root/v2/admin")
        #expect(base.with(base: "https://otro.ejemplo.com").baseURL.absoluteString == "https://otro.ejemplo.com")
    }

    @Test("with(keys:dates:) con formato fijo")
    func formattedDates() throws {
        struct Day: Decodable { let on: Date }
        let dated = AppClient(baseURL: "https://api.ejemplo.com").with(keys: .asIs, dates: .formatted("yyyy-MM-dd"))
        let day = try dated.decoder.decode(Day.self, from: Data(#"{"on": "2026-10-22"}"#.utf8))
        #expect(day.on == Date(timeIntervalSince1970: 1_792_627_200))
    }
}
