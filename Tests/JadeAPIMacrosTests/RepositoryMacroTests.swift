import JadeAPIMacros
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

let macros: [String: Macro.Type] = [
    "Repository": RepositoryMacro.self,
    "Api": ApiMacro.self,
    "Interceptors": RepositoryAttributeMacro.self,
    "Unwrap": RepositoryAttributeMacro.self,
    "Transform": RepositoryAttributeMacro.self,
    "ErrorTransform": RepositoryAttributeMacro.self,
    "Retries": RepositoryAttributeMacro.self,
    "Idempotent": RepositoryAttributeMacro.self,
    "Headers": RepositoryAttributeMacro.self,
    "BaseURL": RepositoryAttributeMacro.self,
    "KeyMapping": RepositoryAttributeMacro.self,
    "Socket": RepositoryAttributeMacro.self,
    "ApiRequest": ApiRequestMacro.self,
    "Parameter": ParameterMarkerMacro.self,
    "Authenticated": RepositoryAttributeMacro.self,
    "Public": RepositoryAttributeMacro.self,
]

final class RepositoryMacroTests: XCTestCase {

    func testGeneratesClient() {
        assertMacroExpansion(
            """
            @Repository
            public protocol UsersRepository {
                @Retry(3)
                @Api("/users/:id")
                func user(id: Int, verbose: Bool) async throws -> User

                @Api("/auth", method: .post)
                func auth(user: String, password: String) async throws -> Token

                @Api
                func deleteUser(id: Int) async throws
            }
            """,
            expandedSource: """
            public protocol UsersRepository {
                @Retry(3)
                func user(id: Int, verbose: Bool) async throws -> User
                func auth(user: String, password: String) async throws -> Token
                func deleteUser(id: Int) async throws
            }

            @AnnotationSwift.Decorable
            public struct UsersRepositoryClient: UsersRepository, Sendable {
                /// Servicio del ``Environment`` al que pertenece este repositorio.
                public static let service: String = JadeAPI.Environment.defaultService

                public let client: JadeAPI.AppClient

                public init(client: JadeAPI.AppClient) {
                    self.client = client
                }

                /// Cliente del servicio `default` resuelto por el entorno.
                public init(environment: JadeAPI.Environment) throws {
                    self.init(client: try environment.client(for: Self.service))
                }

                /// Fábrica: `UsersRepositoryClient.live(in: environment)`.
                public static func live(in environment: JadeAPI.Environment) throws -> UsersRepositoryClient {
                    try UsersRepositoryClient(environment: environment)
                }

                @Retry(3)
                public func user(id: Int, verbose: Bool) async throws -> User {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "user(id:verbose:)", method: .get, path: "/users/:id", pathParameters: ["id": JadeAPI.ParameterValue.text(id) ?? ""], query: [("verbose", JadeAPI.ParameterValue.text(verbose))], headers: __headers, body: nil)
                    return try await client.perform(__endpoint)
                }

                public func auth(user: String, password: String) async throws -> Token {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "auth(user:password:)", method: .post, path: "/auth", pathParameters: [:], query: [], headers: __headers, body: .fields([("user", user), ("password", password)]))
                    return try await client.perform(__endpoint)
                }

                public func deleteUser(id: Int) async throws {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "deleteUser(id:)", method: .delete, path: "/user", pathParameters: [:], query: [("id", JadeAPI.ParameterValue.text(id))], headers: __headers, body: nil)
                    return try await client.performVoid(__endpoint)
                }
            }

            extension UsersRepository where Self == UsersRepositoryClient {
                /// Implementación real resuelta por el entorno: `let repo: UsersRepository = try .live(in: environment)`.
                public static func live(in environment: JadeAPI.Environment) throws -> Self {
                    try UsersRepositoryClient(environment: environment)
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'deleteUser': parameters (id) will be sent as query; if any is a path parameter, declare the route, e.g. @Api(\"/user/:id\")", line: 10, column: 5, severity: .warning),
            ],
            macros: macros
        )
    }

    func testTransformersAndInterceptors() {
        assertMacroExpansion(
            """
            @Repository
            @Unwrap("data")
            @ErrorTransform(APIErrorMapper.self)
            @Interceptors(Trace(name: "repo"))
            protocol ProfilesRepository: Sendable {
                @Transform(ProfileMapper.self)
                @Api("/profiles/:id")
                func profile(id: Int) async throws -> Profile

                @Unwrap("data.items")
                @Api("/profiles")
                func all() async throws -> [UserDTO]

                @Api("/profiles/:id/raw")
                func raw(id: Int) async throws -> String
            }
            """,
            expandedSource: """
            protocol ProfilesRepository: Sendable {
                func profile(id: Int) async throws -> Profile
                func all() async throws -> [UserDTO]
                func raw(id: Int) async throws -> String
            }

            @AnnotationSwift.Decorable
            struct ProfilesRepositoryClient: ProfilesRepository, Sendable {
                /// Servicio del ``Environment`` al que pertenece este repositorio.
                static let service: String = JadeAPI.Environment.defaultService

                let client: JadeAPI.AppClient

                init(client: JadeAPI.AppClient) {
                    self.client = client.with(interceptors: [Trace(name: "repo")])
                }

                /// Cliente del servicio `default` resuelto por el entorno.
                init(environment: JadeAPI.Environment) throws {
                    self.init(client: try environment.client(for: Self.service))
                }

                /// Fábrica: `ProfilesRepositoryClient.live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> ProfilesRepositoryClient {
                    try ProfilesRepositoryClient(environment: environment)
                }

                func profile(id: Int) async throws -> Profile {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "profile(id:)", method: .get, path: "/profiles/:id", pathParameters: ["id": JadeAPI.ParameterValue.text(id) ?? ""], query: [], headers: __headers, body: nil)
                    do {
                        let __input: ProfileMapper.Input = try await client.perform(__endpoint, unwrapping: "data")
                        return try ProfileMapper().transform(__input)
                    } catch {
                        throw client.mapError(error, with: APIErrorMapper.self, unwrapping: "data")
                    }
                }

                func all() async throws -> [UserDTO] {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "all()", method: .get, path: "/profiles", pathParameters: [:], query: [], headers: __headers, body: nil)
                    do {
                        return try await client.perform(__endpoint, unwrapping: "data.items")
                    } catch {
                        throw client.mapError(error, with: APIErrorMapper.self, unwrapping: "data.items")
                    }
                }

                func raw(id: Int) async throws -> String {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "raw(id:)", method: .get, path: "/profiles/:id/raw", pathParameters: ["id": JadeAPI.ParameterValue.text(id) ?? ""], query: [], headers: __headers, body: nil)
                    do {
                        return try await client.performString(__endpoint)
                    } catch {
                        throw client.mapError(error, with: APIErrorMapper.self)
                    }
                }
            }

            extension ProfilesRepository where Self == ProfilesRepositoryClient {
                /// Implementación real resuelta por el entorno: `let repo: ProfilesRepository = try .live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> Self {
                    try ProfilesRepositoryClient(environment: environment)
                }
            }
            """,
            macros: macros
        )
    }

    func testRepositoryAttributesChainTheClient() {
        assertMacroExpansion(
            """
            @Repository
            @BaseURL("/v2")
            @Headers(["X-Client": "ios"])
            @KeyMapping(.snakeCase, dates: .iso8601)
            @Interceptors(Trace(name: "repo"))
            protocol AccountsRepository: Sendable {
                @Headers(["X-Trace": "create"])
                @Api("/accounts", method: .post)
                func create(fullName: String) async throws -> Account
            }
            """,
            expandedSource: """
            protocol AccountsRepository: Sendable {
                func create(fullName: String) async throws -> Account
            }

            @AnnotationSwift.Decorable
            struct AccountsRepositoryClient: AccountsRepository, Sendable {
                /// Servicio del ``Environment`` al que pertenece este repositorio.
                static let service: String = JadeAPI.Environment.defaultService

                let client: JadeAPI.AppClient

                init(client: JadeAPI.AppClient) {
                    self.client = client.with(base: "/v2").with(headers: ["X-Client": "ios"]).with(keys: .snakeCase, dates: .iso8601).with(interceptors: [Trace(name: "repo")])
                }

                /// Cliente del servicio `default` resuelto por el entorno.
                init(environment: JadeAPI.Environment) throws {
                    self.init(client: try environment.client(for: Self.service))
                }

                /// Fábrica: `AccountsRepositoryClient.live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> AccountsRepositoryClient {
                    try AccountsRepositoryClient(environment: environment)
                }

                func create(fullName: String) async throws -> Account {
                    let __headers: [String: String] = ["X-Trace": "create"]
                    let __endpoint = JadeAPI.Endpoint(name: "create(fullName:)", method: .post, path: "/accounts", pathParameters: [:], query: [], headers: __headers, body: .fields([("fullName", fullName)]))
                    return try await client.perform(__endpoint)
                }
            }

            extension AccountsRepository where Self == AccountsRepositoryClient {
                /// Implementación real resuelta por el entorno: `let repo: AccountsRepository = try .live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> Self {
                    try AccountsRepositoryClient(environment: environment)
                }
            }
            """,
            macros: macros
        )
    }

    func testBaseURLOnRequirementIsRejected() {
        assertMacroExpansion(
            """
            @Repository
            protocol BadRepository: Sendable {
                @BaseURL("/v2")
                @Api("/ping")
                func ping() async throws -> String
            }
            """,
            expandedSource: """
            protocol BadRepository: Sendable {
                func ping() async throws -> String
            }

            @AnnotationSwift.Decorable
            struct BadRepositoryClient: BadRepository, Sendable {
                /// Servicio del ``Environment`` al que pertenece este repositorio.
                static let service: String = JadeAPI.Environment.defaultService

                let client: JadeAPI.AppClient

                init(client: JadeAPI.AppClient) {
                    self.client = client
                }

                /// Cliente del servicio `default` resuelto por el entorno.
                init(environment: JadeAPI.Environment) throws {
                    self.init(client: try environment.client(for: Self.service))
                }

                /// Fábrica: `BadRepositoryClient.live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> BadRepositoryClient {
                    try BadRepositoryClient(environment: environment)
                }
            }

            extension BadRepository where Self == BadRepositoryClient {
                /// Implementación real resuelta por el entorno: `let repo: BadRepository = try .live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> Self {
                    try BadRepositoryClient(environment: environment)
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "@BaseURL applies to the whole repository: move it onto the protocol", line: 3, column: 5),
            ],
            macros: macros
        )
    }

    func testSocketPolicyBecomesOptions() {
        assertMacroExpansion(
            """
            @Repository
            protocol ChatRepository: Sendable {
                @Socket("/ws/chat/:room", reconnect: .constant(.seconds(1)), keepAlive: .seconds(30))
                func chat(room: String) async throws -> Socket<String, String>
            }
            """,
            expandedSource: """
            protocol ChatRepository: Sendable {
                func chat(room: String) async throws -> Socket<String, String>
            }

            @AnnotationSwift.Decorable
            struct ChatRepositoryClient: ChatRepository, Sendable {
                /// Servicio del ``Environment`` al que pertenece este repositorio.
                static let service: String = JadeAPI.Environment.defaultService

                let client: JadeAPI.AppClient

                init(client: JadeAPI.AppClient) {
                    self.client = client
                }

                /// Cliente del servicio `default` resuelto por el entorno.
                init(environment: JadeAPI.Environment) throws {
                    self.init(client: try environment.client(for: Self.service))
                }

                /// Fábrica: `ChatRepositoryClient.live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> ChatRepositoryClient {
                    try ChatRepositoryClient(environment: environment)
                }

                func chat(room: String) async throws -> Socket<String, String> {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "chat(room:)", method: .get, path: "/ws/chat/:room", pathParameters: ["room": JadeAPI.ParameterValue.text(room) ?? ""], query: [], headers: __headers, body: nil, options: JadeAPI.RequestOptions(socket: JadeAPI.SocketPolicy(reconnect: .constant(.seconds(1)), keepAlive: .seconds(30))))
                    return try await client.openSocket(__endpoint)
                }
            }

            extension ChatRepository where Self == ChatRepositoryClient {
                /// Implementación real resuelta por el entorno: `let repo: ChatRepository = try .live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> Self {
                    try ChatRepositoryClient(environment: environment)
                }
            }
            """,
            macros: macros
        )
    }

    func testAuthenticatedInjectsOption() {
        assertMacroExpansion(
            """
            @Repository
            @Authenticated
            protocol GuardedRepository: Sendable {
                @Api("/me") func me() async throws -> User
                @Public @Api("/status") func status() async throws -> User
            }
            """,
            expandedSource: """
            protocol GuardedRepository: Sendable {
                func me() async throws -> User
                func status() async throws -> User
            }

            @AnnotationSwift.Decorable
            struct GuardedRepositoryClient: GuardedRepository, Sendable {
                /// Servicio del ``Environment`` al que pertenece este repositorio.
                static let service: String = JadeAPI.Environment.defaultService

                let client: JadeAPI.AppClient

                init(client: JadeAPI.AppClient) {
                    self.client = client
                }

                /// Cliente del servicio `default` resuelto por el entorno.
                init(environment: JadeAPI.Environment) throws {
                    self.init(client: try environment.client(for: Self.service))
                }

                /// Fábrica: `GuardedRepositoryClient.live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> GuardedRepositoryClient {
                    try GuardedRepositoryClient(environment: environment)
                }

                func me() async throws -> User {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "me()", method: .get, path: "/me", pathParameters: [:], query: [], headers: __headers, body: nil, options: JadeAPI.RequestOptions(requiresAuth: true))
                    return try await client.perform(__endpoint)
                }

                func status() async throws -> User {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "status()", method: .get, path: "/status", pathParameters: [:], query: [], headers: __headers, body: nil)
                    return try await client.perform(__endpoint)
                }
            }

            extension GuardedRepository where Self == GuardedRepositoryClient {
                /// Implementación real resuelta por el entorno: `let repo: GuardedRepository = try .live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> Self {
                    try GuardedRepositoryClient(environment: environment)
                }
            }
            """,
            macros: macros
        )
    }

    func testUnsafeRetryIsRejected() {
        assertMacroExpansion(
            """
            @Repository
            @Retries(3)
            protocol Orders {
                @Api("/orders", method: .post)
                func place() async throws

                @Idempotent
                @Api("/orders", method: .post)
                func placeSafely() async throws

                @Retries(1)
                @Api("/orders/:id/cancel", method: .post)
                func cancel(id: Int) async throws
            }
            """,
            expandedSource: """
            protocol Orders {
                func place() async throws
                func placeSafely() async throws
                func cancel(id: Int) async throws
            }

            @AnnotationSwift.Decorable
            struct OrdersClient: Orders, Sendable {
                /// Servicio del ``Environment`` al que pertenece este repositorio.
                static let service: String = JadeAPI.Environment.defaultService

                let client: JadeAPI.AppClient

                init(client: JadeAPI.AppClient) {
                    self.client = client
                }

                /// Cliente del servicio `default` resuelto por el entorno.
                init(environment: JadeAPI.Environment) throws {
                    self.init(client: try environment.client(for: Self.service))
                }

                /// Fábrica: `OrdersClient.live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> OrdersClient {
                    try OrdersClient(environment: environment)
                }

                func placeSafely() async throws {
                    var __headers: [String: String] = [:]
                    __headers["Idempotency-Key"] = Foundation.UUID().uuidString
                    let __endpoint = JadeAPI.Endpoint(name: "placeSafely()", method: .post, path: "/orders", pathParameters: [:], query: [], headers: __headers, body: nil, options: JadeAPI.RequestOptions(retry: JadeAPI.RetryPolicy(attempts: 3)))
                    return try await client.performVoid(__endpoint)
                }

                func cancel(id: Int) async throws {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "cancel(id:)", method: .post, path: "/orders/:id/cancel", pathParameters: ["id": JadeAPI.ParameterValue.text(id) ?? ""], query: [], headers: __headers, body: nil, options: JadeAPI.RequestOptions(retry: JadeAPI.RetryPolicy(attempts: 1)).merging(over: JadeAPI.RequestOptions(retry: JadeAPI.RetryPolicy(attempts: 3))))
                    return try await client.performVoid(__endpoint)
                }
            }

            extension Orders where Self == OrdersClient {
                /// Implementación real resuelta por el entorno: `let repo: Orders = try .live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> Self {
                    try OrdersClient(environment: environment)
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "'place' is a POST and could be executed twice: add @Idempotent (sends an Idempotency-Key) or @Retries(1) to opt out", line: 4, column: 5),
            ],
            macros: macros
        )
    }

    func testDiagnostics() {
        assertMacroExpansion(
            """
            @Repository
            protocol Broken {
                func noApi() async throws -> Int
                @Api func notAsync() throws -> Int
                @Api("/x/\\(y)") func interpolated() async throws -> Int
                @Api("/x", method: "post") func badMethod() async throws -> Int
                @Api("/x", method: .post) func twoBodies(a: Body<Int>, b: Int) async throws -> Int
            }
            """,
            expandedSource: """
            protocol Broken {
                func noApi() async throws -> Int
                func notAsync() throws -> Int
                func interpolated() async throws -> Int
                func badMethod() async throws -> Int
                func twoBodies(a: Body<Int>, b: Int) async throws -> Int
            }

            @AnnotationSwift.Decorable
            struct BrokenClient: Broken, Sendable {
                /// Servicio del ``Environment`` al que pertenece este repositorio.
                static let service: String = JadeAPI.Environment.defaultService

                let client: JadeAPI.AppClient

                init(client: JadeAPI.AppClient) {
                    self.client = client
                }

                /// Cliente del servicio `default` resuelto por el entorno.
                init(environment: JadeAPI.Environment) throws {
                    self.init(client: try environment.client(for: Self.service))
                }

                /// Fábrica: `BrokenClient.live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> BrokenClient {
                    try BrokenClient(environment: environment)
                }

                func interpolated() async throws -> Int {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "interpolated()", method: .get, path: "/interpolated", pathParameters: [:], query: [], headers: __headers, body: nil)
                    return try await client.perform(__endpoint)
                }

                func badMethod() async throws -> Int {
                    let __headers: [String: String] = [:]
                    let __endpoint = JadeAPI.Endpoint(name: "badMethod()", method: .get, path: "/x", pathParameters: [:], query: [], headers: __headers, body: nil)
                    return try await client.perform(__endpoint)
                }
            }

            extension Broken where Self == BrokenClient {
                /// Implementación real resuelta por el entorno: `let repo: Broken = try .live(in: environment)`.
                static func live(in environment: JadeAPI.Environment) throws -> Self {
                    try BrokenClient(environment: environment)
                }
            }
            """,
            diagnostics: [
                DiagnosticSpec(message: "every requirement of a @Repository needs @Api or @Socket", line: 3, column: 10),
                DiagnosticSpec(message: "a @Repository requirement must be declared 'async throws'", line: 4, column: 23),
                DiagnosticSpec(message: "@Api path must be a plain string literal, without interpolation", line: 5, column: 10),
                DiagnosticSpec(message: "@Api method must be written as .get, .post, …", line: 6, column: 24),
                DiagnosticSpec(message: "use a single Body<T> parameter or plain parameters as body fields, not both", line: 7, column: 45),
            ],
            macros: macros
        )
    }

    func testApiOutsideRepository() {
        assertMacroExpansion(
            """
            protocol Plain {
                @Api func getX() async throws -> Int
            }
            @Repository
            struct NotAProtocol {}
            """,
            expandedSource: """
            protocol Plain {
                func getX() async throws -> Int
            }
            struct NotAProtocol {}
            """,
            diagnostics: [
                DiagnosticSpec(message: "@Api has no effect: add @Repository to 'Plain'", line: 2, column: 5),
                DiagnosticSpec(message: "@Repository can only be applied to a protocol", line: 4, column: 1),
            ],
            macros: macros
        )
    }
}
