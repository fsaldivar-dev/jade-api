import CryptoKit
import Foundation
import JadeAPI
import JadeTesting
import Testing

@Suite("Nivel 3: firmas HTTP (RFC 9421)")
struct SignatureTests {

    @Test("La petición firmada lleva Content-Digest, Signature-Input y Signature, y el servidor puede verificarla")
    func signAndVerify() throws {
        let key = try P256SigningKey(preferSecureEnclave: false, keyID: "k1")
        let interceptor = SignedRequestInterceptor(key: key, coveredHeaders: ["idempotency-key", "authorization"], now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let original = Request(method: .post, url: URL(string: "https://api.banco.mx/pagos?x=1")!, path: "/pagos",
                               headers: ["Idempotency-Key": "abc"], body: Data(#"{"amount": 10}"#.utf8))
        let signed = try interceptor.sign(original, nonce: "n-1")

        #expect(signed.headers["Content-Digest"] == "sha-256=:\(Data(SHA256.hash(data: original.body!)).base64EncodedString()):")
        let input = try #require(signed.headers["Signature-Input"])
        #expect(input == "jade=(\"@method\" \"@target-uri\" \"content-digest\" \"idempotency-key\");created=1700000000;keyid=\"k1\";alg=\"ecdsa-p256-sha256\";nonce=\"n-1\"")
        // "authorization" no estaba en la petición: no se cubre, y no rompe.

        // Verificación como la haría el servidor: reconstruir la base y validar ES256 con la JWK de la clave.
        let parameters = String(input.dropFirst("jade=".count))
        let base = SignedRequestInterceptor.signatureBase(request: signed, components: ["@method", "@target-uri", "content-digest", "idempotency-key"], parameters: parameters)
        #expect(base.hasPrefix("\"@method\": POST\n\"@target-uri\": https://api.banco.mx/pagos?x=1\n\"content-digest\": sha-256=:"))
        #expect(base.contains("\n\"idempotency-key\": abc\n\"@signature-params\": ("))
        let signatureField = try #require(signed.headers["Signature"])
        let base64 = signatureField.dropFirst("jade=:".count).dropLast()
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: try #require(Data(base64Encoded: String(base64))))
        #expect(key.publicKey.isValidSignature(signature, for: Data(base.utf8)))
    }

    @Test("Cambiar el body después de firmar invalida la firma (el digest ya no coincide)")
    func tamper() throws {
        let key = try P256SigningKey(preferSecureEnclave: false, keyID: "k1")
        let signed = try SignedRequestInterceptor(key: key).sign(Request(method: .post, url: URL(string: "https://a.b/x")!, path: "/x", body: Data("a".utf8)))
        var tampered = signed
        tampered.body = Data("b".utf8)
        let expected = "sha-256=:\(Data(SHA256.hash(data: tampered.body!)).base64EncodedString()):"
        #expect(tampered.headers["Content-Digest"] != expected)
    }

    @Test("Como interceptor: todas las peticiones salen firmadas, con nonce distinto cada vez")
    func asInterceptor() async throws {
        let mock = MockClient()
        mock.on(.get, "/users/:id") { request in request.headers["Signature"] != nil && request.headers["Signature-Input"] != nil ? .json(#"{"id": 1, "name": "ok"}"#) : .status(401) }
        let key = try P256SigningKey(preferSecureEnclave: false)
        let users: UsersRepository = UsersRepositoryClient(client: AppClient(baseURL: "https://api.banco.mx", transport: mock, interceptors: [SignedRequestInterceptor(key: key)]))
        _ = try await users.user(id: 1)
        _ = try await users.user(id: 1)
        #expect(mock.received[0].headers["Signature-Input"] != mock.received[1].headers["Signature-Input"])
    }
}
