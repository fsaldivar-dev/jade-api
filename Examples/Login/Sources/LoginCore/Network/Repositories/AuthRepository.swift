import JadeAPI

/// Servicio `auth`: login y logout. El protocolo es el contrato; `@Repository` genera `AuthRepositoryClient`.
@Repository(service: "auth")
public protocol AuthRepository: Sendable {
    @Logged
    @Api("/auth", method: .post)
    func login(user: String, password: String) async throws -> Token

    @Logged
    @Api("/auth/logout", method: .post)
    func logout(token: Header<String>) async throws
}

/// Servicio `auth`: perfil del usuario. `@Logged` envuelve a `@Retry`: un solo log para los dos intentos.
@Repository(service: "auth")
public protocol ProfileRepository: Sendable {
    @Logged
    @Retry(2)
    @Api("/me")
    func me(token: Header<String>) async throws -> Profile
}
