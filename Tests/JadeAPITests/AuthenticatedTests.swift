import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Guardián @Authenticated")
struct AuthenticatedTests {

    struct Tokens: TokenProvider {
        let token: String?
        func currentToken() async throws -> String? { token }
        func refreshToken() async throws -> String { throw HTTPError.unauthenticated }
    }

    let mock = MockClient()
    func repo(token: String?) -> GuardedRepository {
        let client = AppClient(baseURL: "https://api.ejemplo.com", transport: mock,
                               interceptors: [AuthInterceptor(tokens: Tokens(token: token))])
        return GuardedRepositoryClient(client: client)
    }

    @Test("sin sesión, el endpoint protegido corta antes de la red")
    func cutsWithoutSession() async throws {
        mock.on(.get, "/me") { _ in .json(#"{"id": 1, "name": "x"}"#) }
        let error = await #expect(throws: HTTPError.self) { try await repo(token: nil).me() }
        guard case .unauthenticated = error else { Issue.record("se esperaba .unauthenticated"); return }
        #expect(mock.received.isEmpty, "no debió salir a la red")
    }

    @Test("con sesión, el endpoint protegido va con el Bearer")
    func passesWithSession() async throws {
        mock.on(.get, "/me") { _ in .json(#"{"id": 1, "name": "Paco"}"#) }
        #expect(try await repo(token: "tok").me().name == "Paco")
        #expect(mock.received.first?.headers["Authorization"] == "Bearer tok")
    }

    @Test("@Public exime del guardián: sin sesión sale igual")
    func publicOptsOut() async throws {
        mock.on(.get, "/status") { _ in .json(#"{"id": 0, "name": "ok"}"#) }
        #expect(try await repo(token: nil).status().name == "ok")
        #expect(mock.received.count == 1)
    }
}
