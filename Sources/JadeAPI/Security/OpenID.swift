import CryptoKit
import Foundation

// MARK: - Discovery (OpenID Connect Discovery 1.0)

/// Lo que publica el servidor en `/.well-known/openid-configuration`. Solo los campos que usamos.
public struct OpenIDConfiguration: Decodable, Sendable, Equatable {
    public let issuer: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let pushedAuthorizationRequestEndpoint: URL?
    public let endSessionEndpoint: URL?
    public let jwksURI: URL?
    public let codeChallengeMethodsSupported: [String]?
    public let dpopSigningAlgValuesSupported: [String]?
    public let requirePushedAuthorizationRequests: Bool?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case pushedAuthorizationRequestEndpoint = "pushed_authorization_request_endpoint"
        case endSessionEndpoint = "end_session_endpoint"
        case jwksURI = "jwks_uri"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case dpopSigningAlgValuesSupported = "dpop_signing_alg_values_supported"
        case requirePushedAuthorizationRequests = "require_pushed_authorization_requests"
    }

    public init(issuer: URL, authorizationEndpoint: URL, tokenEndpoint: URL, pushedAuthorizationRequestEndpoint: URL? = nil, endSessionEndpoint: URL? = nil, jwksURI: URL? = nil, codeChallengeMethodsSupported: [String]? = nil, dpopSigningAlgValuesSupported: [String]? = nil, requirePushedAuthorizationRequests: Bool? = nil) {
        self.issuer = issuer
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.pushedAuthorizationRequestEndpoint = pushedAuthorizationRequestEndpoint
        self.endSessionEndpoint = endSessionEndpoint
        self.jwksURI = jwksURI
        self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        self.dpopSigningAlgValuesSupported = dpopSigningAlgValuesSupported
        self.requirePushedAuthorizationRequests = requirePushedAuthorizationRequests
    }
}

public enum OpenIDError: Error, Equatable, CustomStringConvertible {
    case issuerMismatch(expected: URL, found: URL)
    case insecureEndpoint(URL)
    case stateMismatch
    case authorizationDenied(code: String, description: String?)
    case missingCode
    case nonceMismatch
    case invalidIDToken(String)
    case pkceNotSupported

    public var description: String {
        switch self {
        case .issuerMismatch(let expected, let found): "el issuer descubierto (\(found)) no coincide con \(expected)"
        case .insecureEndpoint(let url): "endpoint inseguro: \(url)"
        case .stateMismatch: "el state de la respuesta no coincide: posible CSRF"
        case .authorizationDenied(let code, let description): "autorización denegada: \(code)\(description.map { " (\($0))" } ?? "")"
        case .missingCode: "la respuesta de autorización no trae code"
        case .nonceMismatch: "el nonce del id_token no coincide"
        case .invalidIDToken(let reason): "id_token inválido: \(reason)"
        case .pkceNotSupported: "el servidor no anuncia PKCE S256 y es obligatorio"
        }
    }
}

/// Descubre y valida la configuración de un issuer. El issuer es lo único que la app conoce por
/// entorno; el resto de endpoints se obtiene de aquí y se comprueba que son `https` y que el
/// `issuer` publicado es exactamente el esperado (OIDC Discovery 4.3).
public struct OpenIDDiscovery: Sendable {
    public let client: AppClient

    public init(client: AppClient) { self.client = client }

    public func configuration(for issuer: URL) async throws -> OpenIDConfiguration {
        var base = client
        base.baseURL = issuer
        let endpoint = Endpoint(name: "openid-configuration", method: .get, path: "/.well-known/openid-configuration")
        let configuration: OpenIDConfiguration = try await base.perform(endpoint)
        try Self.validate(configuration, issuer: issuer, security: client.security)
        return configuration
    }

    public static func validate(_ configuration: OpenIDConfiguration, issuer: URL, security: SecurityPolicy) throws {
        guard normalize(configuration.issuer) == normalize(issuer) else {
            throw OpenIDError.issuerMismatch(expected: issuer, found: configuration.issuer)
        }
        for url in [configuration.authorizationEndpoint, configuration.tokenEndpoint, configuration.pushedAuthorizationRequestEndpoint, configuration.endSessionEndpoint, configuration.jwksURI].compactMap({ $0 }) {
            do { try security.validate(url) } catch { throw OpenIDError.insecureEndpoint(url) }
        }
        if let methods = configuration.codeChallengeMethodsSupported, !methods.contains("S256") {
            throw OpenIDError.pkceNotSupported
        }
    }

    static func normalize(_ url: URL) -> String {
        var text = url.absoluteString.lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

// MARK: - PKCE (RFC 7636)

public struct PKCE: Sendable, Equatable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"

    /// Verifier aleatorio de 32 bytes (43 caracteres base64url) y su challenge S256.
    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.init(verifier: Base64URL.encode(Data(bytes)))
    }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}

// MARK: - Presentación del navegador

/// Abre la URL de autorización en el navegador del sistema (nunca en un WebView: RFC 8252) y devuelve
/// la URL de redirección. `WebAuthenticationPresenter` usa `ASWebAuthenticationSession`; en pruebas,
/// un doble que devuelve la URL directamente.
public protocol AuthorizationPresenter: Sendable {
    func present(_ url: URL, callbackScheme: String) async throws -> URL
}

#if canImport(AuthenticationServices)
import AuthenticationServices

/// `ASWebAuthenticationSession`: cookies compartidas con Safari (SSO), sin WebView, con la UI del sistema.
@MainActor
public final class WebAuthenticationPresenter: NSObject, AuthorizationPresenter, ASWebAuthenticationPresentationContextProviding {
    public let prefersEphemeralSession: Bool

    public init(prefersEphemeralSession: Bool = false) {
        self.prefersEphemeralSession = prefersEphemeralSession
    }

    public nonisolated func present(_ url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callback, error in
                    if let callback { continuation.resume(returning: callback) }
                    else { continuation.resume(throwing: error ?? HTTPError.cancelled) }
                }
                session.prefersEphemeralWebBrowserSession = self.prefersEphemeralSession
                session.presentationContextProvider = self
                session.start()
            }
        }
    }

    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #endif
    }
}
#endif

// MARK: - Flujo: PAR + PKCE + intercambio con DPoP

/// Respuesta del token endpoint (RFC 6749 §5.1, OIDC Core 3.1.3.3).
public struct TokenResponse: Decodable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int?
    public let refreshToken: String?
    public let idToken: String?
    public let scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", tokenType = "token_type", expiresIn = "expires_in"
        case refreshToken = "refresh_token", idToken = "id_token", scope
    }

    public func stored(at date: Date = .now) -> StoredTokens {
        StoredTokens(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresIn.map { date.addingTimeInterval(TimeInterval($0)) })
    }
}

/// Login de app nativa al estilo FAPI 2.0: discovery, PAR (si el servidor lo ofrece o lo exige),
/// PKCE S256, navegador del sistema, intercambio del código con prueba DPoP (si hay clave) y
/// comprobación del `nonce` del `id_token`. El cliente es público: no hay `client_secret`.
///
/// ```swift
/// let flow = AuthorizationFlow(issuer: URL(string: "https://auth.banco.mx")!, clientID: "app-ios",
///                              redirectURI: URL(string: "mx.banco.app://callback")!, scopes: ["openid", "accounts"],
///                              client: try environment.client(for: "auth"), key: deviceKey,
///                              presenter: WebAuthenticationPresenter())
/// let tokens = try await flow.signIn()                 // StoredTokens listos para KeychainTokenProvider
/// try await provider.store(tokens)
/// ```
public struct AuthorizationFlow: Sendable {
    public let issuer: URL
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]
    public let client: AppClient
    /// Clave DPoP: ata los tokens emitidos a este dispositivo.
    public let key: (any SigningKey)?
    public let presenter: any AuthorizationPresenter
    /// Parámetros extra de autorización (`acr_values`, `prompt`, `ui_locales`, …).
    public let extraParameters: [String: String]

    public init(issuer: URL, clientID: String, redirectURI: URL, scopes: [String], client: AppClient, key: (any SigningKey)? = nil, presenter: any AuthorizationPresenter, extraParameters: [String: String] = [:]) {
        self.issuer = issuer
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.client = client
        self.key = key
        self.presenter = presenter
        self.extraParameters = extraParameters
    }

    /// Login completo. Devuelve los tokens; guardarlos es cosa del ``KeychainTokenProvider``.
    public func signIn() async throws -> StoredTokens {
        let configuration = try await OpenIDDiscovery(client: client).configuration(for: issuer)
        let pkce = PKCE()
        let state = Base64URL.encode(Self.random(32))
        let nonce = Base64URL.encode(Self.random(32))
        let url = try await authorizationURL(configuration, pkce: pkce, state: state, nonce: nonce)
        let callback = try await presenter.present(url, callbackScheme: redirectURI.scheme ?? "")
        let code = try Self.code(from: callback, expectedState: state)
        let response = try await exchange(code: code, verifier: pkce.verifier, configuration: configuration)
        if let idToken = response.idToken { try Self.checkIDToken(idToken, nonce: nonce, issuer: issuer, clientID: clientID) }
        return response.stored()
    }

    /// Refresca con el refresh token (para el closure de ``KeychainTokenProvider``).
    public func refresh(_ refreshToken: String) async throws -> StoredTokens {
        let configuration = try await OpenIDDiscovery(client: client).configuration(for: issuer)
        let response = try await token(configuration, form: ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID])
        var stored = response.stored()
        if stored.refreshToken == nil { stored.refreshToken = refreshToken }   // sin rotación: conserva el anterior
        return stored
    }

    // MARK: Autorización

    func authorizationURL(_ configuration: OpenIDConfiguration, pkce: PKCE, state: String, nonce: String) async throws -> URL {
        var parameters: [String: String] = [
            "response_type": "code", "client_id": clientID, "redirect_uri": redirectURI.absoluteString,
            "scope": scopes.joined(separator: " "), "state": state, "nonce": nonce,
            "code_challenge": pkce.challenge, "code_challenge_method": pkce.method,
        ]
        for (key, value) in extraParameters { parameters[key] = value }

        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        if let par = configuration.pushedAuthorizationRequestEndpoint {
            // PAR (RFC 9126): los parámetros viajan por el canal trasero; el navegador solo ve request_uri.
            struct PARResponse: Decodable { let request_uri: String; let expires_in: Int? }
            var base = client
            base.baseURL = par
            let endpoint = Endpoint(name: "par", method: .post, path: "", headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                    body: .value(FormBody(parameters)))
            let pushed: PARResponse = try await base.perform(endpoint)
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "request_uri", value: pushed.request_uri)]
        } else {
            if configuration.requirePushedAuthorizationRequests == true { throw OpenIDError.insecureEndpoint(configuration.authorizationEndpoint) }
            components.queryItems = (components.queryItems ?? []) + parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") { throw OpenIDError.authorizationDenied(code: error, description: value("error_description")) }
        guard value("state") == expectedState else { throw OpenIDError.stateMismatch }
        guard let code = value("code") else { throw OpenIDError.missingCode }
        return code
    }

    // MARK: Token endpoint

    func exchange(code: String, verifier: String, configuration: OpenIDConfiguration) async throws -> TokenResponse {
        try await token(configuration, form: [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI.absoluteString,
            "client_id": clientID, "code_verifier": verifier,
        ])
    }

    private func token(_ configuration: OpenIDConfiguration, form: [String: String]) async throws -> TokenResponse {
        var base = client
        base.baseURL = configuration.tokenEndpoint
        if let key { base.interceptors.append(DPoPInterceptor(key: key)) }    // prueba DPoP sin token: ata lo que se emita
        let endpoint = Endpoint(name: "token", method: .post, path: "", headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                body: .value(FormBody(form)))
        return try await base.perform(endpoint)
    }

    // MARK: id_token

    /// Comprobación de claims del `id_token` recibido directamente del token endpoint por TLS: `iss`,
    /// `aud`, `exp` y `nonce` (OIDC Core 3.1.3.7). La firma no se verifica aquí: en ese canal la
    /// especificación lo permite, y la seguridad del flujo la dan PKCE, TLS y DPoP.
    public static func checkIDToken(_ token: String, nonce: String, issuer: URL, clientID: String, now: Date = .now) throws {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = Base64URL.decode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw OpenIDError.invalidIDToken("formato") }
        guard let iss = claims["iss"] as? String, OpenIDDiscovery.normalize(URL(string: iss) ?? issuer) == OpenIDDiscovery.normalize(issuer) else { throw OpenIDError.invalidIDToken("iss") }
        let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard audiences.contains(clientID) else { throw OpenIDError.invalidIDToken("aud") }
        if let exp = claims["exp"] as? Double, Date(timeIntervalSince1970: exp) < now { throw OpenIDError.invalidIDToken("exp") }
        guard claims["nonce"] as? String == nonce else { throw OpenIDError.nonceMismatch }
    }

    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }
}

/// `application/x-www-form-urlencoded` como body de un `Endpoint`.
public struct FormBody: Encodable, Sendable {
    public let fields: [String: String]
    public init(_ fields: [String: String]) { self.fields = fields }

    public var encoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(encoded)
    }
}
