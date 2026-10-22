import JadeAPI
import Observation

/// Pestaña Sesión: login contra `POST /auth/login` y perfil con `GET /auth/me`.
///
/// Qué enseña: un repositorio declarado (`AuthRepository`), el token puesto por `AuthInterceptor`
/// (el store nunca lo pasa a mano) y los decoradores `@Logged` y `@Retry` en el log.
@MainActor
@Observable
public final class SessionStore {
    public enum Status: Equatable { case signedOut, signingIn, signedIn(Profile) }

    public private(set) var status: Status = .signedOut
    public private(set) var errorMessage: String?

    private let auth: any AuthRepository
    private let tokens: SessionTokens

    public init(auth: any AuthRepository, tokens: SessionTokens) {
        self.auth = auth
        self.tokens = tokens
    }

    public var isSignedIn: Bool { if case .signedIn = status { true } else { false } }

    public func signIn(username: String, password: String) async {
        status = .signingIn
        errorMessage = nil
        do {
            let token = try await auth.login(username: username, password: password, expiresInMins: 30)
            await tokens.set(token)                        // desde aquí, AuthInterceptor manda el Bearer
            let profile = try await auth.me()
            status = .signedIn(profile)
        } catch {
            await tokens.set(nil)
            status = .signedOut
            errorMessage = describe(error)
        }
    }

    /// dummyjson no tiene logout: cerrar sesión es olvidar el token.
    public func signOut() async {
        await tokens.set(nil)
        status = .signedOut
    }
}

/// Un `HTTPError` tiene descripción legible; el resto se muestra tal cual.
func describe(_ error: any Error) -> String {
    switch error {
    case let http as HTTPError: http.description
    default: "\(error)"
    }
}
