import JadeAPI

/// Fuente de tokens para `AuthInterceptor`. Se inyecta desde la raíz de composición: nada de singletons.
///
/// `refreshToken()` se llama cuando una petición con token recibe 401. Esta guía no renueva: pide volver
/// a entrar. En una app real aquí se llamaría a `POST /auth/refresh` con el `refreshToken` guardado
/// (ver `KeychainTokenProvider` en JadeAPI para guardarlo en el llavero).
public actor SessionTokens: TokenProvider {
    private var token: Token?

    public init() {}

    public func set(_ token: Token?) { self.token = token }

    public func currentToken() async throws -> String? { token?.accessToken }

    public func refreshToken() async throws -> String {
        throw SessionExpired()
    }
}

public struct SessionExpired: Error, CustomStringConvertible {
    public var description: String { "la sesión caducó: vuelve a entrar" }
}
