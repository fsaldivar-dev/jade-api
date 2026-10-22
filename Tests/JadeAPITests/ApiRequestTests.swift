import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Objetos de petición (@ApiRequest)")
struct ApiRequestTests {

    let mock = MockClient()
    var accounts: AccountsRequestRepository {
        AccountsRequestRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: mock))
    }

    @Test("POST: @Parameter va al body, Header<> va al header")
    func createSendsBodyAndHeader() async throws {
        mock.on(.post, "/users") { _ in .json(#"{"id": 1, "name": "Paco"}"#) }
        _ = try await accounts.create(NewUser(name: "Paco", age: 30, trace: Header("t-1")))
        let request = try #require(mock.received.first)
        #expect(request.method == .post)
        #expect(request.path == "/users")
        #expect(request.headers["trace"] == "t-1")
        let body = try #require(request.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["name"] as? String == "Paco")
        #expect(json?["age"] as? Int == 30)
        #expect(json?["trace"] == nil)        // el header no viaja en el body
    }

    @Test("GET: @Parameter va a la query, Path<> rellena la ruta, nil se omite")
    func searchSendsQueryAndPath() async throws {
        mock.on(.get, "/sections/:section/users") { _ in .json("[]") }
        _ = try await accounts.search(UserQuery(q: "paco", limit: nil, section: Path("admin")))
        let request = try #require(mock.received.first)
        #expect(request.path == "/sections/admin/users")
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "q" }?.value == "paco")
        #expect(!items.contains { $0.name == "limit" })   // nil omitido
    }

    @Test("El mismo objeto manda query en GET y body en POST")
    func parameterInfersByVerb() {
        let query = UserQuery(q: "x", limit: 5, section: Path("s"))
        let get = query._inputs(method: .get)
        #expect(get.query.contains { $0.0 == "q" })
        #expect(get.body == nil)

        let user = NewUser(name: "A", age: nil, trace: Header("t"))
        let post = user._inputs(method: .post)
        #expect(post.headers["trace"] == "t")
        if case .fields(let fields)? = post.body {
            #expect(fields.contains { $0.0 == "name" })
        } else {
            Issue.record("se esperaba body por campos en POST")
        }
    }
}
