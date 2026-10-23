import Foundation

// MARK: - Headers comunes

/// Añade headers a todas las peticiones. Los del endpoint ganan si coinciden.
public struct CommonHeaders: RequestAdapter {
    public let headers: [String: String]
    public init(_ headers: [String: String]) {
        self.headers = headers
        SecurityAudit.checkStaticHeaders(headers, origin: "CommonHeaders")
    }

    public func adapt(_ request: Request) async throws -> Request {
        var request = request
        for (name, value) in headers where request.headers[name] == nil { request.headers[name] = value }
        return request
    }
}

// MARK: - Log

/// Escribe cada petición y respuesta, redactando credenciales y datos sensibles en headers, query y body.
///
/// En una build de release no escribe nada salvo que se cree con `enabledInRelease: true`; un log de
/// red en producción es una fuga de datos esperando a ocurrir.
public struct RequestLogger: Interceptor {
    public enum Style: Sendable { case line, curl }

    public let style: Style
    public let policy: SecurityPolicy
    public let enabledInRelease: Bool
    public let sink: @Sendable (String) -> Void

    public init(_ style: Style = .line, policy: SecurityPolicy = .default, enabledInRelease: Bool = false, sink: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.style = style
        self.policy = policy
        self.enabledInRelease = enabledInRelease
        self.sink = sink
    }

    /// Compatibilidad: `redacting:` añade claves a las sensibles de la política.
    public init(_ style: Style = .line, redacting extra: Set<String>, sink: @escaping @Sendable (String) -> Void = { print($0) }) {
        var policy = SecurityPolicy.default
        policy.sensitiveKeys.formUnion(extra.map { $0.lowercased() })
        self.init(style, policy: policy, sink: sink)
    }

    var isEnabled: Bool { SecurityPolicy.isDebugBuild || enabledInRelease }

    public func intercept(_ request: Request, next: Next) async throws -> Response {
        guard isEnabled else { return try await next(request) }
        var shown = request
        for (name, value) in shown.headers { shown.headers[name] = policy.redacted(name, value) }
        if let url = URL(string: policy.redactedQuery(of: request.url)) { shown.url = url }
        if let body = policy.redactedBody(request.body) { shown.body = Data(body.utf8) }
        switch style {
        case .line: sink("→ \(request.method.rawHTTP) \(request.path)  [\(request.endpoint)]")
        case .curl: sink("→ \(shown.curl)")
        }
        let start = ContinuousClock.now
        do {
            let response = try await next(request)
            var line = "← \(response.status) \(request.method.rawHTTP) \(request.path)  \(response.body.count) bytes  \((ContinuousClock.now - start).millisecondsText)"
            if let metrics = response.metrics {
                if let ttfb = metrics.timeToFirstByte { line += "  ttfb \(ttfb.millisecondsText)" }
                if let name = metrics.protocolName { line += "  \(name)" }
                if metrics.reusedConnection { line += "  reused" }
            }
            if response.attempts > 1 { line += "  intento \(response.attempts)" }
            sink(line)
            return response
        } catch {
            sink("✗ \(request.method.rawHTTP) \(request.path)  \(error)")
            throw error
        }
    }
}

// MARK: - Métricas

/// Lo que ``MetricsInterceptor`` entrega por petición terminada, con la petición ya redactada.
public struct MetricsReport: Sendable {
    /// Petición con credenciales y datos sensibles redactados según la ``SecurityPolicy``.
    public var request: Request
    /// Status de la respuesta, o `nil` si no hubo respuesta (error de transporte, timeout, cancelación).
    public var status: Int?
    /// Error, si la petición falló antes de responder.
    public var error: String?
    /// Tiempo total visto desde este interceptor: incluye reintentos, caché y espera de single-flight.
    public var elapsed: Duration
    /// Intentos que hizo `@Retries` (1 = a la primera).
    public var attempts: Int
    /// Lo que midió el transporte en el intento que respondió; `nil` si no mide o no hubo respuesta.
    public var transport: TransportMetrics?

    public var succeeded: Bool { status.map { (200..<300).contains($0) } ?? false }
}

/// Entrega un ``MetricsReport`` por petición a un `sink`: la forma de conectar Datadog, Firebase
/// Performance o tu propio panel sin tocar repositorios. Colócalo lo más afuera posible (capa de
/// entorno o cliente) para que `elapsed` incluya reintentos y refresh de token.
///
/// ```swift
/// environment.interceptors = [MetricsInterceptor { report in telemetry.record(report) }]
/// ```
public struct MetricsInterceptor: Interceptor {
    public let policy: SecurityPolicy
    public let sink: @Sendable (MetricsReport) -> Void

    public init(policy: SecurityPolicy = .default, sink: @escaping @Sendable (MetricsReport) -> Void) {
        self.policy = policy
        self.sink = sink
    }

    public func intercept(_ request: Request, next: Next) async throws -> Response {
        let start = ContinuousClock.now
        var shown = request
        for (name, value) in shown.headers { shown.headers[name] = policy.redacted(name, value) }
        if let url = URL(string: policy.redactedQuery(of: request.url)) { shown.url = url }
        if let body = policy.redactedBody(request.body) { shown.body = Data(body.utf8) }
        do {
            let response = try await next(request)
            sink(MetricsReport(request: shown, status: response.status, error: nil, elapsed: ContinuousClock.now - start,
                               attempts: response.attempts, transport: response.metrics))
            return response
        } catch {
            sink(MetricsReport(request: shown, status: nil, error: "\(error)", elapsed: ContinuousClock.now - start, attempts: 1, transport: nil))
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
/// Una petición que salió sin token (no había sesión) no dispara el refresh: su 401 se devuelve tal cual.
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
        // Guardián @Authenticated: sin token, el endpoint protegido no llega a la red.
        if request.options.requiresAuth, token == nil { throw HTTPError.unauthenticated }
        if let token { request.headers[header] = "\(scheme) \(token)" }
        let response = try await next(request)
        // Sin token no hay nada que refrescar: ese 401 es la respuesta (p. ej. un login con credenciales malas).
        guard let token, refreshOn.contains(response.status) else { return response }
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
