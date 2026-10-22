import CryptoKit
import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Nivel 3: DPoP (RFC 9449)")
struct DPoPTests {

    /// Verifica una prueba DPoP como lo haría el servidor: estructura, claims y firma ES256 con la JWK del header.
    static func verify(_ proof: String) throws -> (header: [String: Any], payload: [String: Any]) {
        let parts = proof.split(separator: ".").map(String.init)
        #expect(parts.count == 3)
        let header = try JSONSerialization.jsonObject(with: try #require(decode(parts[0]))) as! [String: Any]
        let payload = try JSONSerialization.jsonObject(with: try #require(decode(parts[1]))) as! [String: Any]
        let jwk = header["jwk"] as! [String: String]
        let x = try #require(decode(jwk["x"]!)), y = try #require(decode(jwk["y"]!))
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(decode(parts[2])))
        #expect(publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        return (header, payload)
    }

    static func decode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    @Test("La prueba lleva typ, alg, jwk, htm, htu sin query, iat, jti y ath, y la firma verifica")
    func proof() throws {
        let key = try P256SigningKey(preferSecureEnclave: false, keyID: "k1")
        let proof = try DPoPProof(key: key).make(method: .post, url: URL(string: "https://api.banco.mx/pagos?x=1#f")!, accessToken: "tok", nonce: "n1")
        let (header, payload) = try Self.verify(proof)
        #expect(header["typ"] as? String == "dpop+jwt")
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "k1")
        #expect(payload["htm"] as? String == "POST")
        #expect(payload["htu"] as? String == "https://api.banco.mx/pagos")
        #expect(payload["nonce"] as? String == "n1")
        #expect((payload["jti"] as? String)?.isEmpty == false)
        #expect(payload["ath"] as? String == Base64URLTest.encode(Data(SHA256.hash(data: Data("tok".utf8)))))
    }

    @Test("La clave se persiste en el KeychainStore y se recupera con el mismo keyID y la misma clave pública")
    func persistence() throws {
        let store = InMemoryKeychainStore()
        let first = try P256SigningKey.load(from: store, preferSecureEnclave: false)
        let again = try P256SigningKey.load(from: store, preferSecureEnclave: false)
        #expect(first.keyID == again.keyID)
        #expect(first.jwk == again.jwk)
        #expect(!first.isSecureEnclave)
    }

    @Test("Interceptor: Authorization DPoP, header DPoP por petición, y reintento único con DPoP-Nonce")
    func interceptor() async throws {
        let mock = MockClient()
        let key = try P256SigningKey(preferSecureEnclave: false)
        let tokens = CountingTokens(token: "acc")
        mock.on(.get, "/users/:id") { request in
            guard request.headers["Authorization"] == "DPoP acc", let proof = request.headers["DPoP"] else { return .status(400) }
            let payload = try JSONSerialization.jsonObject(with: Self.decode(proof.split(separator: ".").map(String.init)[1])!) as! [String: Any]
            if payload["nonce"] as? String != "srv-nonce" {
                return MockResponse(status: 401, headers: ["DPoP-Nonce": "srv-nonce"], body: Data(#"{"error":"use_dpop_nonce"}"#.utf8))
            }
            return .json(#"{"id": 1, "name": "ok"}"#)
        }
        let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://api.banco.mx", transport: mock, interceptors: [DPoPInterceptor(key: key, tokens: tokens)]))
        #expect(try await users.user(id: 1).name == "ok")
        #expect(mock.received.count == 2)                                 // sin nonce → con nonce
        #expect(mock.received[0].headers["DPoP"] != mock.received[1].headers["DPoP"])   // jti distinto por prueba
        _ = try await users.user(id: 2)
        #expect(mock.received.count == 3)                                 // el nonce ya se conocía: una sola petición
    }
}

enum Base64URLTest {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
