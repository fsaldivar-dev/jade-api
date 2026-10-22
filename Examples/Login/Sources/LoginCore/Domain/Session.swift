import Foundation

/// Token de sesión emitido por el servicio `auth`.
public struct Token: Codable, Sendable, Equatable {
    public let value: String
    public let expiresIn: Int

    public init(value: String, expiresIn: Int) {
        self.value = value
        self.expiresIn = expiresIn
    }
}

/// Perfil del usuario autenticado.
public struct Profile: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let role: String

    public init(id: Int, name: String, role: String) {
        self.id = id
        self.name = name
        self.role = role
    }
}
