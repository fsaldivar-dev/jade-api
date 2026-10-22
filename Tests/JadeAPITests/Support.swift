import Foundation
import JadeAPI
import JadeTesting

// MARK: - Modelos

struct User: Codable, Equatable, Sendable { let id: Int; let name: String }
struct Token: Codable, Equatable, Sendable { let value: String }
struct Credentials: Codable, Equatable, Sendable { let user: String; let password: String }

// MARK: - Decorador del usuario, apilado sobre requisitos del protocolo.
// @Annotation + el plugin AnnotationRegistry (activado en Package.swift) generan la declaración de @Retry.

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

    @Decorate(Retry(3))
    @Api("/users/:id/flaky-inline")
    func flakyInline(id: Int) async throws -> User                               // sin marcador declarado

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

// MARK: - Interceptores de prueba

/// Anota su nombre al entrar y al salir, para comprobar el orden de la cadena.
struct Trace: Interceptor {
    let name: String
    let log: TraceLog
    func intercept(_ request: Request, next: Next) async throws -> Response {
        log.append("\(name) →")
        var request = request
        request.headers["X-Trace"] = (request.headers["X-Trace"].map { $0 + "," } ?? "") + name
        let response = try await next(request)
        log.append("\(name) ←")
        return response
    }
}

final class TraceLog: @unchecked Sendable {
    private let lock = NSLock(); private var lines: [String] = []
    func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

/// Proveedor de tokens que cuenta los refresh.
actor CountingTokens: TokenProvider {
    var token: String?
    var refreshes = 0
    let refreshDelay: Duration
    init(token: String?, refreshDelay: Duration = .milliseconds(50)) { self.token = token; self.refreshDelay = refreshDelay }
    func currentToken() async throws -> String? { token }
    func refreshToken() async throws -> String {
        refreshes += 1
        try await Task.sleep(for: refreshDelay)
        token = "fresh-\(refreshes)"
        return token!
    }
}

@Repository
@Interceptors(CommonHeaders(["X-Repo": "payments"]))
protocol PaymentsRepository: Sendable {
    @Api("/payments/:id")
    func payment(id: Int) async throws -> Response
}

// MARK: - Transformadores de prueba

struct UserDTO: Decodable { let id: Int; let full_name: String }
struct Profile: Equatable, Sendable { let id: Int; let name: String }

struct ProfileMapper: Transformer {
    func transform(_ dto: UserDTO) throws -> Profile { Profile(id: dto.id, name: dto.full_name) }
}

struct APIErrorBody: Decodable { let code: String; let message: String }
enum DomainError: Error, Equatable { case api(code: String, message: String) }

struct APIErrorMapper: Transformer {
    func transform(_ body: APIErrorBody) throws -> DomainError { .api(code: body.code, message: body.message) }
}

@Repository
@Unwrap("data")
@ErrorTransform(APIErrorMapper.self)
protocol ProfilesRepository: Sendable {
    @Transform(ProfileMapper.self)
    @Api("/profiles/:id")
    func profile(id: Int) async throws -> Profile              // {data: UserDTO} → Profile

    @Unwrap("data.items")
    @Api("/profiles")
    func all() async throws -> [UserDTO]                       // el @Unwrap del requisito gana

    @Transform(ProfileMapper.self)
    @Unwrap("result")
    @Api("/profiles/:id/alt")
    func alternative(id: Int) async throws -> Profile          // Unwrap + Transform juntos
}

// MARK: - Opciones de petición

@Repository
@Retries(3, backoff: .constant(.milliseconds(10)))
protocol CatalogRepository: Sendable {
    @CacheFor(.seconds(60))
    @Api("/catalog")
    func catalog() async throws -> [User]

    @SingleFlight
    @Api("/catalog/featured")
    func featured() async throws -> [User]

    @Api("/catalog/slow", timeout: .milliseconds(80))
    func slow() async throws -> [User]

    @Retries(1)
    @Api("/catalog/no-retry")
    func noRetry() async throws -> [User]

    @Api("/catalog/:id")
    func item(id: Int) async throws -> User
}

/// Cuenta cuántas peticiones están en vuelo a la vez y el máximo alcanzado.
final class ConcurrencyMeter: @unchecked Sendable {
    private let lock = NSLock(); private var current = 0; private(set) var peak = 0
    func enter() { lock.lock(); current += 1; peak = max(peak, current); lock.unlock() }
    func exit() { lock.lock(); current -= 1; lock.unlock() }
}

// MARK: - Nivel 1: defaults seguros

@Repository
@Retries(3, backoff: .constant(.milliseconds(5)))
protocol OrdersRepository: Sendable {
    @Idempotent
    @Api("/orders", method: .post)
    func place(order: String) async throws -> User          // POST reintentable: lleva Idempotency-Key

    @Retries(1)
    @Api("/orders/:id/cancel", method: .post)
    func cancel(id: Int) async throws                        // POST sin reintentos: permitido sin @Idempotent

    @Api("/orders/:id")
    func order(id: Int) async throws -> User                 // GET: hereda los reintentos del protocolo
}

// MARK: - Nivel 2: servicios

@Repository(service: "payments")
protocol WalletRepository: Sendable {
    @Api("/wallet")
    func wallet() async throws -> Response
}

@Repository(service: "users")
protocol AccountRepository: Sendable {
    @Api("/account")
    func account() async throws -> Response
}

/// Sin `service:` → servicio por defecto.
@Repository
protocol PingRepository: Sendable {
    @Api("/ping")
    func ping() async throws -> Response
}

enum FixturePlist {
    static var twoServices: [String: Any] { [
        "stage": "staging",
        "headers": ["Accept": "application/json", "X-App": "jade"],
        "services": [
            "users": ["baseURL": "https://users.staging.ejemplo.com/v2"],
            "payments": [
                "baseURL": "https://payments.staging.ejemplo.com/v3",
                "headers": ["X-Service": "payments"],
                "timeout": "10",
                "retries": 0,
                "cache": "30",
            ],
        ],
    ] }
}

// MARK: - Fase 3a: streams

struct Chunk: Decodable, Sendable, Equatable { let index: Int; let text: String }

@Repository
protocol FeedRepository: Sendable {
    @Api("/export", kind: .bytes)
    func export() async throws -> AsyncThrowingStream<Data, any Error>

    @Api("/log", kind: .lines)
    func log() async throws -> AsyncThrowingStream<String, any Error>

    @Api("/completions", method: .post, kind: .ndjson)
    func complete(prompt: String) async throws -> AsyncThrowingStream<Chunk, any Error>

    @Api("/events", kind: .sse)
    func events() async throws -> AsyncThrowingStream<ServerEvent, any Error>
}

// MARK: - Fase 3b: transferencias

@Repository
protocol FilesRepository: Sendable {
    @Api("/files/:id", kind: .download)
    func export(id: Int) async throws -> Download

    @Api("/media", method: .post, kind: .upload)
    func upload(file: Body<FileUpload>) async throws -> Upload

    @Api("/media/raw", method: .put, kind: .upload)
    func uploadRaw(payload: Body<Data>) async throws -> Upload
}
