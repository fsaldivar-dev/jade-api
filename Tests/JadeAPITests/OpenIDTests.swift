import CryptoKit
import Foundation
import JadeAPI
import JadeTesting
import Testing

/// Presentador falso: "el usuario" aprueba y el servidor redirige con code y el state recibido.
struct FakePresenter: AuthorizationPresenter {
    let behavior: @Sendable (URL) -> URL
    func present(_ url: URL, callbackScheme: String) async throws -> URL { behavior(url) }
}

@Suite("Nivel 3: login OIDC con discovery, PAR, PKCE y DPoP")
struct OpenIDTests {

    static let issuer = URL(string: "https://auth.banco.mx")!

    static func discoveryJSON(par: Bool) -> String {
        """
        {"issuer": "https://auth.banco.mx", "authorization_endpoint": "https://auth.banco.mx/authorize",
         "token_endpoint": "https://auth.banco.mx/token", "jwks_uri": "https://auth.banco.mx/jwks",
         "code_challenge_methods_supported": ["S256"], "dpop_signing_alg_values_supported": ["ES256"]
         \(par ? #", "pushed_authorization_request_endpoint": "https://auth.banco.mx/par", "require_pushed_authorization_requests": true"# : "")}
        """
    }

    static func idToken(nonce: String, exp: TimeInterval = Date.now.timeIntervalSince1970 + 300, aud: String = "app-ios") -> String {
        let header = Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)
        let payload = try! JSONSerialization.data(withJSONObject: ["iss": "https://auth.banco.mx/", "aud": aud, "exp": exp, "nonce": nonce, "sub": "paco"])
        return [header, payload, Data("sig".utf8)].map { Base64URLTest.encode($0) }.joined(separator: ".")
    }

    func flow(mock: MockClient, presenter: FakePresenter, key: (any SigningKey)? = nil) -> AuthorizationFlow {
        AuthorizationFlow(issuer: Self.issuer, clientID: "app-ios", redirectURI: URL(string: "mx.banco.app://callback")!,
                          scopes: ["openid", "accounts"], client: AppClient(baseURL: "https://auth.banco.mx", transport: mock),
                          key: key, presenter: presenter, extraParameters: ["acr_values": "urn:banco:sca"])
    }

    @Test("PKCE: vector de la RFC 7636 (apéndice B)")
    func pkceVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE().verifier.count == 43)
        #expect(PKCE().verifier != PKCE().verifier)
    }

    @Test("Discovery: issuer validado y endpoints https; un issuer distinto o un endpoint http se rechazan")
    func discovery() async throws {
        let mock = MockClient().on(.get, "/.well-known/openid-configuration") { _ in .json(Self.discoveryJSON(par: true)) }
        let configuration = try await OpenIDDiscovery(client: AppClient(baseURL: "https://auth.banco.mx", transport: mock)).configuration(for: Self.issuer)
        #expect(configuration.pushedAuthorizationRequestEndpoint?.path == "/par")

        #expect(throws: OpenIDError.issuerMismatch(expected: URL(string: "https://otro.mx")!, found: Self.issuer)) {
            try OpenIDDiscovery.validate(configuration, issuer: URL(string: "https://otro.mx")!, security: .default)
        }
        let insecure = OpenIDConfiguration(issuer: Self.issuer, authorizationEndpoint: URL(string: "http://auth.banco.mx/authorize")!, tokenEndpoint: configuration.tokenEndpoint)
        #expect(throws: OpenIDError.insecureEndpoint(URL(string: "http://auth.banco.mx/authorize")!)) {
            try OpenIDDiscovery.validate(insecure, issuer: Self.issuer, security: SecurityPolicy(allowsInsecureHTTP: false))
        }
        let noPKCE = OpenIDConfiguration(issuer: Self.issuer, authorizationEndpoint: configuration.authorizationEndpoint, tokenEndpoint: configuration.tokenEndpoint, codeChallengeMethodsSupported: ["plain"])
        #expect(throws: OpenIDError.pkceNotSupported) { try OpenIDDiscovery.validate(noPKCE, issuer: Self.issuer, security: .default) }
    }

    @Test("Flujo completo con PAR: el navegador solo ve request_uri; el token endpoint recibe code_verifier y una prueba DPoP; el nonce del id_token se comprueba")
    func fullFlowWithPAR() async throws {
        let mock = MockClient()
        let key = try P256SigningKey(preferSecureEnclave: false)
        let nonces = Counter()
        mock.on(.get, "/.well-known/openid-configuration") { _ in .json(Self.discoveryJSON(par: true)) }
        mock.on(.post, "/par") { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            guard request.headers["Content-Type"] == "application/x-www-form-urlencoded",
                  body.contains("client_id=app-ios"), body.contains("code_challenge_method=S256"), body.contains("acr_values=urn%3Abanco%3Asca"),
                  body.contains("scope=openid%20accounts"), body.contains("redirect_uri=mx.banco.app%3A%2F%2Fcallback") else { return .status(400, body: body) }
            return .json(#"{"request_uri": "urn:ietf:params:oauth:request_uri:abc", "expires_in": 60}"#, status: 201)
        }
        mock.on(.post, "/token") { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            guard request.headers["DPoP"] != nil, request.headers["Authorization"] == nil else { return .status(400, body: "sin DPoP") }
            guard body.contains("grant_type=authorization_code"), body.contains("code=c0d3"), body.contains("code_verifier=") else { return .status(400, body: body) }
            // id_token con el nonce que mandó la app (lo recuperamos del PAR en un flujo real; aquí lo leemos del body del PAR registrado)
            let parBody = String(decoding: mock.received.first { $0.url.path == "/par" }?.body ?? Data(), as: UTF8.self)
            let nonce = parBody.split(separator: "&").first { $0.hasPrefix("nonce=") }.map { String($0.dropFirst(6)) } ?? ""
            _ = nonces.increment()
            return .json(#"{"access_token": "at", "token_type": "DPoP", "expires_in": 900, "refresh_token": "rt", "id_token": "\#(Self.idToken(nonce: nonce.removingPercentEncoding ?? nonce))"}"#)
        }
        let presenter = FakePresenter { url in
            // El navegador recibe solo client_id y request_uri (PAR), nunca el scope ni el challenge.
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(url.path == "/authorize")
            #expect(items.first { $0.name == "request_uri" }?.value == "urn:ietf:params:oauth:request_uri:abc")
            #expect(items.first { $0.name == "code_challenge" } == nil)
            // …pero la app sí mandó state en el PAR y el servidor lo devuelve en el callback.
            let parBody = String(decoding: mock.received.first { $0.url.path == "/par" }?.body ?? Data(), as: UTF8.self)
            let state = parBody.split(separator: "&").first { $0.hasPrefix("state=") }.map { String($0.dropFirst(6)) } ?? ""
            return URL(string: "mx.banco.app://callback?code=c0d3&state=\(state)")!
        }
        let tokens = try await flow(mock: mock, presenter: presenter, key: key).signIn()
        #expect(tokens.accessToken == "at" && tokens.refreshToken == "rt")
        #expect(tokens.expiresAt != nil)
        #expect(nonces.increment() == 2)
    }

    @Test("Sin PAR: la URL de autorización lleva todos los parámetros y el challenge S256 del verifier que luego viaja al token endpoint")
    func flowWithoutPAR() async throws {
        let mock = MockClient()
        mock.on(.get, "/.well-known/openid-configuration") { _ in .json(Self.discoveryJSON(par: false)) }
        let challenges = SeenValues()
        mock.on(.post, "/token") { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            let verifier = body.split(separator: "&").first { $0.hasPrefix("code_verifier=") }.map { String($0.dropFirst(14)) } ?? ""
            #expect(PKCE(verifier: verifier).challenge == challenges.last)
            return .json(#"{"access_token": "at", "token_type": "Bearer"}"#)
        }
        let presenter = FakePresenter { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            challenges.append(items.first { $0.name == "code_challenge" }!.value!)
            #expect(items.first { $0.name == "code_challenge_method" }?.value == "S256")
            #expect(items.first { $0.name == "nonce" } != nil)
            return URL(string: "mx.banco.app://callback?code=x&state=\(items.first { $0.name == "state" }!.value!)")!
        }
        let tokens = try await flow(mock: mock, presenter: presenter).signIn()
        #expect(tokens.accessToken == "at" && tokens.refreshToken == nil)
    }

    @Test("state distinto, error del servidor y nonce incorrecto se rechazan")
    func rejections() async throws {
        let mock = MockClient()
        mock.on(.get, "/.well-known/openid-configuration") { _ in .json(Self.discoveryJSON(par: false)) }
        let csrf = flow(mock: mock, presenter: FakePresenter { _ in URL(string: "mx.banco.app://callback?code=x&state=otro")! })
        await #expect(throws: OpenIDError.stateMismatch) { try await csrf.signIn() }

        let denied = flow(mock: mock, presenter: FakePresenter { _ in URL(string: "mx.banco.app://callback?error=access_denied&error_description=user")! })
        await #expect(throws: OpenIDError.authorizationDenied(code: "access_denied", description: "user")) { try await denied.signIn() }

        mock.on(.post, "/token") { _ in .json(#"{"access_token": "at", "token_type": "Bearer", "id_token": "\#(Self.idToken(nonce: "equivocado"))"}"#) }
        let badNonce = flow(mock: mock, presenter: FakePresenter { url in
            let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
            return URL(string: "mx.banco.app://callback?code=x&state=\(state)")!
        })
        await #expect(throws: OpenIDError.nonceMismatch) { try await badNonce.signIn() }
    }

    @Test("id_token: iss, aud y exp se comprueban")
    func idTokenClaims() throws {
        let good = Self.idToken(nonce: "n")
        try AuthorizationFlow.checkIDToken(good, nonce: "n", issuer: Self.issuer, clientID: "app-ios")
        #expect(throws: OpenIDError.invalidIDToken("aud")) { try AuthorizationFlow.checkIDToken(Self.idToken(nonce: "n", aud: "otra-app"), nonce: "n", issuer: Self.issuer, clientID: "app-ios") }
        #expect(throws: OpenIDError.invalidIDToken("exp")) { try AuthorizationFlow.checkIDToken(Self.idToken(nonce: "n", exp: 1), nonce: "n", issuer: Self.issuer, clientID: "app-ios") }
        #expect(throws: OpenIDError.invalidIDToken("iss")) { try AuthorizationFlow.checkIDToken(good, nonce: "n", issuer: URL(string: "https://otro.mx")!, clientID: "app-ios") }
    }

    @Test("refresh: grant_type=refresh_token y, sin rotación, conserva el refresh token anterior")
    func refresh() async throws {
        let mock = MockClient()
        mock.on(.get, "/.well-known/openid-configuration") { _ in .json(Self.discoveryJSON(par: false)) }
        mock.on(.post, "/token") { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            return body.contains("grant_type=refresh_token") && body.contains("refresh_token=rt1") ? .json(#"{"access_token": "at2", "token_type": "Bearer", "expires_in": 60}"#) : .status(400, body: body)
        }
        let tokens = try await flow(mock: mock, presenter: FakePresenter { $0 }).refresh("rt1")
        #expect(tokens.accessToken == "at2" && tokens.refreshToken == "rt1")
    }
}

final class SeenValues: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var last: String? { lock.lock(); defer { lock.unlock() }; return values.last }
}
