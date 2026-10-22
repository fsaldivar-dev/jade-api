import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Nivel 3: tokens en el Keychain")
struct KeychainTests {

    @Test("Guarda, lee en caché, y borra")
    func storeAndClear() async throws {
        let store = InMemoryKeychainStore()
        let provider = KeychainTokenProvider(store: store) { _ in StoredTokens(accessToken: "x") }
        #expect(try await provider.currentToken() == nil)
        try await provider.store(StoredTokens(accessToken: "acc", refreshToken: "ref", expiresAt: .now + 3600))
        #expect(store.keys == ["jade.session"])
        #expect(try await provider.currentToken() == "acc")
        try await provider.clear()
        #expect(store.keys.isEmpty)
        #expect(try await provider.currentToken() == nil)
    }

    @Test("Un access token caducado se refresca solo y la sesión nueva se persiste")
    func refreshWhenExpired() async throws {
        let store = InMemoryKeychainStore()
        let refreshes = Counter()
        let provider = KeychainTokenProvider(store: store) { refreshToken in
            _ = refreshes.increment()
            #expect(refreshToken == "ref-1")
            return StoredTokens(accessToken: "acc-2", refreshToken: "ref-2", expiresAt: .now + 3600)
        }
        try await provider.store(StoredTokens(accessToken: "acc-1", refreshToken: "ref-1", expiresAt: .now - 1))
        #expect(try await provider.currentToken() == "acc-2")
        #expect(refreshes.increment() == 2)
        let persisted = try JSONDecoder().decode(StoredTokens.self, from: try #require(try store.read("jade.session")))
        #expect(persisted.accessToken == "acc-2" && persisted.refreshToken == "ref-2")
    }

    @Test("Sin refresh token, refrescar lanza un 401")
    func noRefreshToken() async throws {
        let provider = KeychainTokenProvider(store: InMemoryKeychainStore()) { _ in StoredTokens(accessToken: "x") }
        try await provider.store(StoredTokens(accessToken: "acc"))
        await #expect(throws: HTTPError.self) { try await provider.refreshToken() }
    }

    @Test("Integrado con AuthInterceptor: 401 → refresh desde el Keychain → reintento")
    func withAuthInterceptor() async throws {
        let mock = MockClient()
        mock.on(.get, "/users/:id") { request in
            request.headers["Authorization"] == "Bearer fresh" ? .json(#"{"id": 1, "name": "ok"}"#) : .status(401)
        }
        let provider = KeychainTokenProvider(store: InMemoryKeychainStore()) { _ in StoredTokens(accessToken: "fresh", refreshToken: "r2") }
        try await provider.store(StoredTokens(accessToken: "stale", refreshToken: "r1"))
        let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://api.ejemplo.com", transport: mock, interceptors: [AuthInterceptor(tokens: provider)]))
        #expect(try await users.user(id: 1).name == "ok")
        #expect(mock.received.count == 2)
        #expect(try await provider.current()?.refreshToken == "r2")
    }

    @Test("La caducidad admite un margen")
    func leeway() {
        let tokens = StoredTokens(accessToken: "a", expiresAt: .now + 10)
        #expect(tokens.isExpired(leeway: 30))
        #expect(!tokens.isExpired(leeway: 5))
        #expect(!StoredTokens(accessToken: "a").isExpired())
    }
}
