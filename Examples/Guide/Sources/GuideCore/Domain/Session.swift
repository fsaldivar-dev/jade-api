import Foundation

/// Lo que devuelve `POST /auth/login` de dummyjson.com. Solo guardamos lo que usamos.
public struct Token: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
}

/// `GET /auth/me`: el usuario de la sesión.
public struct Profile: Codable, Sendable, Equatable {
    public let id: Int
    public let username: String
    public let firstName: String
    public let lastName: String
    public let image: URL?

    public var fullName: String { "\(firstName) \(lastName)" }
}
