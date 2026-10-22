import Foundation
import JadeAPI

/// Errores propios del entorno de pruebas.
public enum MockError: Error, CustomStringConvertible {
    /// Un `MockClient` recibió una petición sin handler registrado.
    case unmocked(Request)
    public var description: String {
        if case .unmocked(let request) = self { return "sin mock para \(request.method.rawHTTP) \(request.path)" }
        return ""
    }
}

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

    /// Respuesta por trozos para `kind: .bytes/.lines/.ndjson/.sse`.
    public struct MockStream: Sendable {
        public var status: Int
        public var headers: [String: String]
        public var chunks: [Data]
        /// Pausa entre trozos, para probar consumo incremental y cancelación.
        public var interval: Duration

        public init(status: Int = 200, headers: [String: String] = [:], chunks: [Data], interval: Duration = .zero) {
            self.status = status
            self.headers = headers
            self.chunks = chunks
            self.interval = interval
        }

        /// Trozos de texto, por ejemplo líneas NDJSON o un bloque SSE partido donde quieras.
        public static func text(_ pieces: [String], status: Int = 200, interval: Duration = .zero) -> MockStream {
            MockStream(status: status, chunks: pieces.map { Data($0.utf8) }, interval: interval)
        }
    }
    public typealias StreamHandler = @Sendable (Request) throws -> MockStream

    private struct Route { let method: HTTPMethod; let segments: [Substring]; let handler: Handler }
    private struct StreamRoute { let method: HTTPMethod; let segments: [Substring]; let handler: StreamHandler }
    private let lock = NSLock()
    private var routes: [Route] = []
    private var streamRoutes: [StreamRoute] = []
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

    /// Registra una respuesta por trozos. Si una petición de stream no tiene ruta aquí, se usa `on(_:_:_:)` de una pieza.
    @discardableResult
    public func onStream(_ method: HTTPMethod, _ pathTemplate: String, _ handler: @escaping StreamHandler) -> Self {
        lock.lock(); defer { lock.unlock() }
        streamRoutes.append(StreamRoute(method: method, segments: pathTemplate.split(separator: "/"), handler: handler))
        return self
    }

    public func stream(_ request: Request) async throws -> StreamingResponse {
        record(request)
        if latency > .zero { try await Task.sleep(for: latency) }
        try Task.checkCancellation()
        let handler: StreamHandler? = {
            lock.lock(); defer { lock.unlock() }
            let segments = request.path.split(separator: "/")
            return streamRoutes.last { route in
                route.method == request.method && route.segments.count == segments.count &&
                zip(route.segments, segments).allSatisfy { $0.hasPrefix(":") || $0 == $1 }
            }?.handler
        }()
        guard let handler else { return StreamingResponse(try await sendWithoutRecording(request)) }
        let mock = try handler(request)
        let chunks = AsyncThrowingStream<Data, any Error> { continuation in
            let task = Task {
                for chunk in mock.chunks {
                    if mock.interval > .zero { try await Task.sleep(for: mock.interval) }
                    try Task.checkCancellation()
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return StreamingResponse(status: mock.status, headers: mock.headers, request: request, chunks: chunks)
    }

    /// Peticiones recibidas, en orden.
    public var received: [Request] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    private func record(_ request: Request) {
        lock.lock(); defer { lock.unlock() }
        log.append(request)
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        routes.removeAll(); streamRoutes.removeAll(); log.removeAll()
    }

    public func send(_ request: Request) async throws -> Response {
        // Se registra al recibirla, antes de la latencia: una petición cancelada por timeout también "salió".
        record(request)
        return try await sendWithoutRecording(request)
    }

    private func sendWithoutRecording(_ request: Request) async throws -> Response {
        if latency > .zero { try await Task.sleep(for: latency) }
        try Task.checkCancellation()
        let handler: Handler? = {
            lock.lock(); defer { lock.unlock() }
            let segments = request.path.split(separator: "/")
            return routes.last { route in
                route.method == request.method && route.segments.count == segments.count &&
                zip(route.segments, segments).allSatisfy { $0.hasPrefix(":") || $0 == $1 }
            }?.handler
        }()
        guard let handler else { throw MockError.unmocked(request) }
        let mock = try handler(request)
        return Response(status: mock.status, headers: mock.headers, body: mock.body, request: request)
    }
}

extension Environment {
    /// Un solo servicio en mock, el resto como esté: así se prueba un módulo sin levantar todo.
    ///
    /// ```swift
    /// let environment = try Environment(plist: fixturePlist).mocking("payments", with: MockClient()
    ///     .on(.post, "/charges") { _ in .json(Fixtures.charge) })
    /// ```
    public func mocking(_ service: String = Environment.defaultService, with mock: MockClient) -> Environment {
        overriding(service: service, transport: mock)
    }

    /// Todos los servicios al mismo mock.
    public func mockingAll(with mock: MockClient) -> Environment {
        var copy = self
        for name in services.keys { copy = copy.overriding(service: name, transport: mock) }
        return copy
    }
}

extension MockClient: TransferClient {

    /// Descarga simulada: el body del mock se escribe en `destination` (o en temporal) en `steps`
    /// pasos de progreso separados por `latency`. Un status fuera de 2xx falla como una petición normal.
    public func download(_ request: Request, to destination: URL?) throws -> Download {
        let state = TransferStateBox<URL>()
        let task = Task { [latency] in
            do {
                let response = try await self.send(request)
                guard response.isSuccess else { throw HTTPError.status(response.status, response) }
                let total = Int64(response.body.count)
                let steps: Int64 = 4
                for step in 1...steps {
                    if latency > .zero { try await Task.sleep(for: latency / Int(steps)) }
                    try Task.checkCancellation()
                    state.report(TransferProgress(bytesTransferred: total * step / steps, totalBytes: total))
                }
                let target = destination ?? FileManager.default.temporaryDirectory.appendingPathComponent("jade-mock-\(UUID().uuidString)")
                try response.body.write(to: target)
                state.finish(target)
            } catch is CancellationError {
                state.fail(HTTPError.cancelled)
            } catch {
                state.fail(error)
            }
        }
        return state.download(request: request, controls: DownloadControls(
            cancel: { task.cancel() },
            pause: { task.cancel(); return nil },
            resume: {}))
    }

    public func upload(_ request: Request, body: UploadBody) throws -> Upload {
        let state = TransferStateBox<Response>()
        let task = Task {
            do {
                let size: Int64
                switch body {
                case .data(let data): size = Int64(data.count)
                case .file(let url): size = Int64((try? Data(contentsOf: url).count) ?? 0)
                }
                for step in 1...4 as ClosedRange<Int64> {
                    try Task.checkCancellation()
                    state.report(TransferProgress(bytesTransferred: size * step / 4, totalBytes: size))
                }
                let response = try await self.send(request)
                guard response.isSuccess else { throw HTTPError.status(response.status, response) }
                state.finish(response)
            } catch is CancellationError {
                state.fail(HTTPError.cancelled)
            } catch {
                state.fail(error)
            }
        }
        return state.upload(request: request) { task.cancel() }
    }
}

/// Atajo de nivel superior para `MockClient.MockStream`.
public typealias MockStream = MockClient.MockStream
