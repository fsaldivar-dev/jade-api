import Foundation
import JadeAPI

// MARK: - Modelos

struct User: Codable, Equatable, Sendable { let id: Int; let name: String }
struct Token: Codable, Equatable, Sendable { let value: String }
struct Credentials: Codable, Equatable, Sendable { let user: String; let password: String }

// MARK: - Decorador del usuario, apilado sobre requisitos del protocolo

@attached(peer) macro Retry(_ attempts: Int) = #externalMacro(module: "AnnotationMacros", type: "MarkerMacro")

struct Retry: Decorator {
    let attempts: Int
    init(_ attempts: Int) { self.attempts = attempts }

    func decorate<Out>(_ call: Call, _ next: () throws -> Out) rethrows -> Out {
        for _ in 1..<attempts { if let out = try? next() { return out } }
        return try next()
    }
    func decorate<Out>(_ call: Call, isolation: isolated (any Actor)?, _ next: () async throws -> Out) async rethrows -> Out {
        for _ in 1..<attempts { if let out = try? await next() { return out } }
        return try await next()
    }
}

// MARK: - Repositorios bajo prueba

@Repository
protocol UsersRepository: Sendable {
    @Api
    func getUser(id: Int) async throws -> User                                   // GET /user?id=

    @Api("/users/:id")
    func user(id: Int) async throws -> User                                      // GET /users/7

    @Api("/users/search")
    func search(q: String, page: Int?, limit: Query<Int>) async throws -> [User] // query, nil omitido

    @Retry(3)
    @Api("/users/:id/flaky")
    func flaky(id: Int) async throws -> User                                     // decorador copiado

    @Api
    func deleteUser(id: Int) async throws                                        // DELETE /user?id= → Void

    @Api("/users/:id/avatar")
    func avatar(id: Int) async throws -> Data

    @Api("/users/:id/bio")
    func bio(id: Int) async throws -> String

    @Api("/users/:id/raw")
    func raw(id: Int) async throws -> Response

    @Api("/users/me")
    func me(token: Header<String>) async throws -> User
}

@Repository
protocol AuthRepository: Sendable {
    @Api("/auth", method: .post)
    func auth(user: String, password: String) async throws -> Token              // body {user, password}

    @Api("/auth/login", method: .post)
    func login(credentials: Body<Credentials>) async throws -> Token            // body = credentials

    @Api
    func postRefresh(token: String) async throws -> Token                        // POST /refresh, body {token}

    @Api
    func createSession() async throws -> Token                                   // POST /session
}

// MARK: - Entornos

enum Stage: String, StageProtocol {
    case dev, prod, mock
    var baseURL: URL {
        switch self {
        case .dev: URL(string: "https://dev.api.ejemplo.com/v1")!
        case .prod: URL(string: "https://api.ejemplo.com/v1")!
        case .mock: URL(string: "https://mock.local")!
        }
    }
}
