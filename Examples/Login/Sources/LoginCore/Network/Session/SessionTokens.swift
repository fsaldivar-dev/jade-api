import JadeAPI

/// Fuente de tokens para `AuthInterceptor`. Se inyecta desde la raíz de composición: nada de singletons.
///
/// En esta demo el "refresh" devuelve el mismo token; una app real pediría uno nuevo al servidor
/// (ver `KeychainTokenProvider` y `AuthorizationFlow` en JadeAPI).
public actor SessionTokens: TokenProvider {
    private var token: String?

    public init() {}

    public func set(_ token: String?) { self.token = token }

    public func currentToken() async throws -> String? { token }

    public func refreshToken() async throws -> String {
        guard let token else { throw CatalogError.api(code: "NO_SESSION", message: "inicia sesión") }
        return token
    }
}
