import JadeAPI

/// Servicio `auth` (dummyjson.com). El protocolo es el contrato; `@Repository` genera `AuthRepositoryClient`.
///
/// Usuarios de prueba: `emilys` / `emilyspass`, `michaelw` / `michaelwpass`.
/// El token no se pasa a mano: `AuthInterceptor` (ver `AppEnvironment`) lo pone en cada petición.
@Repository(service: "auth")
public protocol AuthRepository: Sendable {
    /// POST /auth/login con body `{"username": …, "password": …, "expiresInMins": …}`.
    @Logged
    @Api("/auth/login", method: .post)
    func login(username: String, password: String, expiresInMins: Int) async throws -> Token

    /// GET /auth/me con `Authorization: Bearer …`. `@Logged` envuelve a `@Retry`: un solo log para los dos intentos.
    @Logged
    @Retry(2)
    @Api("/auth/me")
    func me() async throws -> Profile
}
