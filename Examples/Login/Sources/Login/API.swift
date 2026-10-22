import Foundation
import JadeAPI

// MARK: - Modelos

struct Token: Codable, Sendable { let value: String; let expiresIn: Int }
struct Profile: Codable, Sendable { let id: Int; let name: String; let role: String }

// MARK: - Repositorios: la declaración es el contrato

// Los decoradores se apilan directo: `Logged` y `Retry` están marcados @Annotation más abajo y el
// plugin AnnotationRegistry (activado en Package.swift) genera sus declaraciones al compilar.

@Repository(service: "auth")
protocol AuthRepository: Sendable {
    @Logged
    @Api("/auth", method: .post)
    func login(user: String, password: String) async throws -> Token

    @Logged
    @Api("/auth/logout", method: .post)
    func logout(token: Header<String>) async throws
}

@Repository(service: "auth")
protocol ProfileRepository: Sendable {
    @Logged
    @Retry(2)                            // Logged envuelve a Retry: un solo log para los dos intentos
    @Api("/me")
    func me(token: Header<String>) async throws -> Profile
}

// MARK: - Decoradores del usuario: tipos normales marcados @Annotation

/// Deja rastro de cada llamada en el panel de la app.
@Annotation
struct Logged: HookDecorator {
    func willCall(_ call: Call) { Log.append("→ \(call.function)") }
    func didReturn(_ call: Call, result: Any) { Log.append("← \(call.function) ok") }
    func didThrow(_ call: Call, error: any Error) { Log.append("✗ \(call.function): \(error)") }
}

@Annotation
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

/// Registro compartido entre decoradores y UI.
enum Log {
    nonisolated(unsafe) private static var lines: [String] = []
    private static let lock = NSLock()
    static func append(_ line: String) { lock.lock(); lines.insert(line, at: 0); lock.unlock() }
    static var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
