import Foundation

// MARK: - Headers comunes

/// Añade headers a todas las peticiones. Los del endpoint ganan si coinciden.
public struct CommonHeaders: RequestAdapter {
    public let headers: [String: String]
    public init(_ headers: [String: String]) { self.headers = headers }

    public func adapt(_ request: Request) async throws -> Request {
        var request = request
        for (name, value) in headers where request.headers[name] == nil { request.headers[name] = value }
        return request
    }
}

// MARK: - Log

/// Escribe cada petición y respuesta. Redacta los headers sensibles.
public struct RequestLogger: Interceptor {
    public enum Style: Sendable { case line, curl }

    public let style: Style
    public let redacting: Set<String>
    public let sink: @Sendable (String) -> Void

    public init(_ style: Style = .line, redacting: Set<String> = ["Authorization", "Cookie", "Set-Cookie"], sink: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.style = style
        self.redacting = redacting
        self.sink = sink
    }

    public func intercept(_ request: Request, next: Next) async throws -> Response {
        var shown = request
        for name in redacting where shown.headers[name] != nil { shown.headers[name] = "•••" }
        switch style {
        case .line: sink("→ \(request.method.rawHTTP) \(request.path)  [\(request.endpoint)]")
        case .curl: sink("→ \(shown.curl)")
        }
        let start = ContinuousClock.now
        do {
            let response = try await next(request)
            sink("← \(response.status) \(request.method.rawHTTP) \(request.path)  \(response.body.count) bytes  \(ContinuousClock.now - start)")
            return response
        } catch {
            sink("✗ \(request.method.rawHTTP) \(request.path)  \(error)")
            throw error
        }
    }
}

// MARK: - Autenticación

/// Fuente de tokens. `refresh()` se invoca una sola vez aunque haya N peticiones en vuelo con 401.
public protocol TokenProvider: Sendable {
    /// Token actual, o `nil` si no hay sesión (la petición sale sin header).
    func currentToken() async throws -> String?
    /// Obtiene un token nuevo. Lanza si no se puede (sesión caducada de verdad).
    func refreshToken() async throws -> String
}

/// Inyecta `Authorization` y, ante un status de la lista (401 por defecto), refresca el token una
/// sola vez y repite la petición. Varias peticiones simultáneas comparten el mismo refresh.
public struct AuthInterceptor: Interceptor {
    public let tokens: any TokenProvider
    public let header: String
    public let scheme: String
    public let refreshOn: Set<Int>
    private let coordinator = RefreshCoordinator()

    public init(tokens: any TokenProvider, header: String = "Authorization", scheme: String = "Bearer", refreshOn: Set<Int> = [401]) {
        self.tokens = tokens
        self.header = header
        self.scheme = scheme
        self.refreshOn = refreshOn
    }

    public func intercept(_ request: Request, next: Next) async throws -> Response {
        var request = request
        let token = try await tokens.currentToken()
        if let token { request.headers[header] = "\(scheme) \(token)" }
        let response = try await next(request)
        guard refreshOn.contains(response.status) else { return response }
        let fresh = try await coordinator.refresh(stale: token, using: tokens)
        request.headers[header] = "\(scheme) \(fresh)"
        return try await next(request)
    }
}

/// Un refresh a la vez: quien llega mientras hay uno en curso espera ese mismo resultado.
actor RefreshCoordinator {
    private var inFlight: Task<String, any Error>?
    private var lastFresh: String?

    func refresh(stale: String?, using tokens: any TokenProvider) async throws -> String {
        // Si otro ya refrescó después de que este token quedó viejo, reutiliza.
        if let lastFresh, lastFresh != stale { return lastFresh }
        if let inFlight { return try await inFlight.value }
        let task = Task { try await tokens.refreshToken() }
        inFlight = task
        defer { inFlight = nil }
        let fresh = try await task.value
        lastFresh = fresh
        return fresh
    }
}
