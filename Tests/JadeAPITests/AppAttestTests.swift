import CryptoKit
import Foundation
import JadeAPI
import JadeTesting
import Testing

/// Doble de App Attest: "firma" con HMAC sobre una clave por keyID, suficiente para verificar el flujo.
final class FakeAttestor: Attestor, @unchecked Sendable {
    let lock = NSLock()
    var supported = true
    var keys: [String: SymmetricKey] = [:]
    var attestCalls = 0, assertCalls = 0, invalidate = false

    var isSupported: Bool { supported }
    func generateKey() async throws -> String {
        lock.withLock {
            let id = "key-\(keys.count + 1)"; keys[id] = SymmetricKey(size: .bits256); return id
        }
    }
    func attest(keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock {
            attestCalls += 1
            return Data(HMAC<SHA256>.authenticationCode(for: Data("attest".utf8) + clientDataHash, using: keys[keyID]!))
        }
    }
    func assert(keyID: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            if invalidate { throw AppAttestError.keyInvalidated }
            assertCalls += 1
            return Data(HMAC<SHA256>.authenticationCode(for: clientDataHash, using: keys[keyID]!))
        }
    }
}

struct FixedChallenge: ChallengeProvider {
    let value: Data
    func challenge() async throws -> Data { value }
}

@Suite("Nivel 3: App Attest")
struct AppAttestTests {

    @Test("Primera petición: atesta y asierta; las siguientes solo asiertan; el keyID se persiste")
    func flow() async throws {
        let mock = MockClient()
        let attestor = FakeAttestor()
        let store = InMemoryKeychainStore()
        let challenge = Data("challenge-1".utf8)
        mock.on(.get, "/users/:id") { request in
            guard request.headers["X-App-Attest-Key-ID"] != nil, request.headers["X-App-Assertion"] != nil,
                  request.headers["X-App-Challenge"] == challenge.base64EncodedString() else { return .status(403) }
            return .json(#"{"id": 1, "name": "ok"}"#)
        }
        let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://api.banco.mx", transport: mock,
            interceptors: [AppAttestInterceptor(attestor: attestor, challenges: FixedChallenge(value: challenge), store: store)]))

        _ = try await users.user(id: 1)
        #expect(mock.received[0].headers["X-App-Attestation"] != nil)
        #expect(attestor.attestCalls == 1 && attestor.assertCalls == 1)
        #expect(store.keys == ["jade.appattest.key"])

        _ = try await users.user(id: 2)
        #expect(mock.received[1].headers["X-App-Attestation"] == nil)     // ya atestada
        #expect(attestor.attestCalls == 1 && attestor.assertCalls == 2)
        #expect(mock.received[0].headers["X-App-Attest-Key-ID"] == mock.received[1].headers["X-App-Attest-Key-ID"])

        // La aserción cubre método, ruta, digest y challenge: el servidor puede recomputar el hash.
        let request = mock.received[1]
        let expectedHash = AppAttestInterceptor.clientDataHash(request: request, challenge: challenge)
        let key = attestor.keys[request.headers["X-App-Attest-Key-ID"]!]!
        let expected = Data(HMAC<SHA256>.authenticationCode(for: expectedHash, using: key)).base64EncodedString()
        #expect(request.headers["X-App-Assertion"] == expected)
    }

    @Test("Si la atestación falla en el servidor, el keyID no se persiste y se reintenta la próxima vez")
    func attestationRejected() async throws {
        let mock = MockClient()
        let attestor = FakeAttestor()
        let store = InMemoryKeychainStore()
        let counter = Counter()
        mock.on(.get, "/users/:id") { _ in counter.increment() == 1 ? .status(403) : .json(#"{"id": 1, "name": "ok"}"#) }
        let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://api.banco.mx", transport: mock,
            interceptors: [AppAttestInterceptor(attestor: attestor, challenges: FixedChallenge(value: Data("c".utf8)), store: store)]))
        await #expect(throws: HTTPError.self) { try await users.user(id: 1) }
        #expect(store.keys.isEmpty)
        _ = try await users.user(id: 1)
        #expect(attestor.attestCalls == 2)
        #expect(store.keys == ["jade.appattest.key"])
    }

    @Test("Clave invalidada: se olvida y se lanza keyInvalidated; sin soporte: unsupported")
    func invalidatedAndUnsupported() async throws {
        let mock = MockClient()
        let attestor = FakeAttestor()
        let store = InMemoryKeychainStore()
        try store.write("jade.appattest.key", Data("key-1".utf8))
        attestor.keys["key-1"] = SymmetricKey(size: .bits256)
        attestor.invalidate = true
        let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://api.banco.mx", transport: mock,
            interceptors: [AppAttestInterceptor(attestor: attestor, challenges: FixedChallenge(value: Data("c".utf8)), store: store)]))
        await #expect(throws: AppAttestError.keyInvalidated) { try await users.user(id: 1) }
        #expect(store.keys.isEmpty)

        attestor.supported = false
        await #expect(throws: AppAttestError.unsupported) { try await users.user(id: 1) }
    }
}
