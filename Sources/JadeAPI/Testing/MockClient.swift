import Foundation

/// Respuesta de un mock.
public struct MockResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// JSON desde un string literal.
    public static func json(_ text: String, status: Int = 200) -> MockResponse {
        MockResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
    }

    /// JSON desde un valor `Encodable`.
    public static func json(_ value: some Encodable, status: Int = 200, encoder: JSONEncoder = JSONEncoder()) throws -> MockResponse {
        MockResponse(status: status, headers: ["Content-Type": "application/json"], body: try encoder.encode(value))
    }

    public static func status(_ code: Int, body: String = "") -> MockResponse {
        MockResponse(status: code, body: Data(body.utf8))
    }

    public static let noContent = MockResponse(status: 204)
}

/// Transporte falso: responde por verbo y plantilla de ruta, sin red.
///
/// ```swift
/// let mock = MockClient()
///     .on(.get, "/users/:id") { request in .json(#"{"id": 7, "name": "Paco"}"#) }
///     .on(.post, "/auth") { _ in .status(401) }
/// ```
///
/// Las peticiones recibidas quedan en ``received`` para afirmar sobre ellas.
public final class MockClient: HTTPClient, @unchecked Sendable {

    public typealias Handler = @Sendable (Request) throws -> MockResponse

    private struct Route { let method: HTTPMethod; let segments: [Substring]; let handler: Handler }
    private let lock = NSLock()
    private var routes: [Route] = []
    private var log: [Request] = []
    /// Latencia artificial por petición, para probar cancelación y timeouts.
    public var latency: Duration = .zero

    public init() {}

    @discardableResult
    public func on(_ method: HTTPMethod, _ pathTemplate: String, _ handler: @escaping Handler) -> Self {
        lock.lock(); defer { lock.unlock() }
        routes.append(Route(method: method, segments: pathTemplate.split(separator: "/"), handler: handler))
        return self
    }

    /// Peticiones recibidas, en orden.
    public var received: [Request] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        routes.removeAll(); log.removeAll()
    }

    public func send(_ request: Request) async throws -> Response {
        if latency > .zero { try await Task.sleep(for: latency) }
        try Task.checkCancellation()
        let handler: Handler? = {
            lock.lock(); defer { lock.unlock() }
            log.append(request)
            let segments = request.path.split(separator: "/")
            return routes.last { route in
                route.method == request.method && route.segments.count == segments.count &&
                zip(route.segments, segments).allSatisfy { $0.hasPrefix(":") || $0 == $1 }
            }?.handler
        }()
        guard let handler else { throw HTTPError.unmocked(request) }
        let mock = try handler(request)
        return Response(status: mock.status, headers: mock.headers, body: mock.body, request: request)
    }
}
