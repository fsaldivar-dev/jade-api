import Foundation

/// Configuración común de un API: base, codificación, headers y transporte.
/// Es lo que recibe el `init(client:)` de cada repositorio generado.
public struct AppClient: Sendable {
    public var baseURL: URL
    public var transport: any HTTPClient
    public var decoder: JSONDecoder
    public var encoder: JSONEncoder
    /// Headers que van en todas las peticiones. Los del endpoint tienen prioridad.
    public var headers: [String: String]
    public var timeout: TimeInterval
    /// Cadena de interceptores: el primero es el más externo; el último habla con el transporte.
    public var interceptors: [any Interceptor]
    /// Opciones por defecto para todos los endpoints del cliente; las del repositorio y el endpoint ganan.
    public var options: RequestOptions = .none
    /// Defaults seguros: solo HTTPS fuera de Debug, redacción en logs.
    public var security: SecurityPolicy = .default
    private let engine = OptionsEngine()

    public init(
        baseURL: URL,
        transport: any HTTPClient = URLSessionClient(),
        interceptors: [any Interceptor] = [],
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        headers: [String: String] = ["Accept": "application/json"],
        timeout: TimeInterval = 30
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.interceptors = interceptors
        self.decoder = decoder
        self.encoder = encoder
        self.headers = headers
        self.timeout = timeout
        SecurityAudit.checkStaticHeaders(headers, origin: "AppClient(headers:)")
    }

    /// Copia del cliente con interceptores añadidos por dentro de los existentes
    /// (cliente → repositorio → red). Lo usa `@Interceptors` a nivel de repositorio.
    public func with(interceptors extra: [any Interceptor]) -> AppClient {
        var copy = self
        copy.interceptors.append(contentsOf: extra)
        return copy
    }

    /// Atajo con un string; falla en tiempo de ejecución si no es una URL.
    public init(baseURL: String, transport: any HTTPClient = URLSessionClient(), interceptors: [any Interceptor] = []) {
        guard let url = URL(string: baseURL) else { preconditionFailure("AppClient: '\(baseURL)' no es una URL válida") }
        self.init(baseURL: url, transport: transport, interceptors: interceptors)
    }

    /// Toma base y transporte del entorno.
    public init(stage: some StageProtocol, interceptors: [any Interceptor] = [], decoder: JSONDecoder = JSONDecoder(), encoder: JSONEncoder = JSONEncoder(), headers: [String: String] = ["Accept": "application/json"], timeout: TimeInterval = 30) {
        self.init(baseURL: stage.baseURL, transport: stage.transport, interceptors: interceptors, decoder: decoder, encoder: encoder, headers: headers, timeout: timeout)
    }

    // MARK: - Construcción de la petición

    /// Convierte un ``Endpoint`` en una ``Request`` absoluta con el body codificado.
    public func makeRequest(_ endpoint: Endpoint) throws -> Request {
        try security.validate(baseURL)
        let path = try endpoint.resolvedPath()
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HTTPError.invalidURL(baseURL.absoluteString)
        }
        // `resolvedPath()` ya viene percent-encoded: se asigna como tal para no codificar dos veces.
        let basePath = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = basePath + (path.hasPrefix("/") ? path : "/" + path)
        let items = endpoint.query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        if !items.isEmpty { components.queryItems = (components.queryItems ?? []) + items }
        guard let url = components.url else { throw HTTPError.invalidURL(components.description) }

        var headers = self.headers
        var body: Data?
        if let content = endpoint.body {
            do {
                switch content {
                case .value(let value): body = try encoder.encode(AnyEncodable(value))
                case .fields(let fields): body = try encoder.encode(FieldsBody(fields))
                }
            } catch {
                throw HTTPError.encoding(error)
            }
            headers["Content-Type"] = headers["Content-Type"] ?? "application/json"
        }
        for (name, value) in endpoint.headers { headers[name] = value }

        return Request(method: endpoint.method, url: url, path: path, headers: headers, body: body, timeout: timeout, endpoint: endpoint.name,
                       options: endpoint.options.merging(over: options))
    }

    // MARK: - Streams (los interceptores solo adaptan la petición; la respuesta no termina)

    /// Abre un stream y valida el status antes de devolverlo. Si el servidor responde fuera de 2xx,
    /// lee el body completo y lanza ``HTTPError/status(_:_:)`` como una petición normal.
    public func performStreaming(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> StreamingResponse {
        var request = try makeRequest(endpoint)
        for interceptor in interceptors {
            if let adapter = interceptor as? any RequestAdapter { request = try await adapter.adapt(request) }
        }
        if let timeout = request.options.timeout {
            request.timeout = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        }
        let streaming = try await transport.stream(request)
        guard streaming.isSuccess else {
            var body = Data()
            for try await chunk in streaming.chunks { body.append(chunk) }
            throw HTTPError.status(streaming.status, Response(status: streaming.status, headers: streaming.headers, body: body, request: request))
        }
        return streaming
    }

    /// `kind: .bytes` → trozos crudos.
    public func performBytes(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> AsyncThrowingStream<Data, any Error> {
        try await performStreaming(endpoint, isolation: isolation).chunks
    }

    /// `kind: .lines` → líneas de texto.
    public func performLines(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> AsyncThrowingStream<String, any Error> {
        StreamParsing.lines(try await performStreaming(endpoint, isolation: isolation).chunks)
    }

    /// `kind: .ndjson` → un elemento decodificado por línea.
    public func performNDJSON<Element: Decodable & Sendable>(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> AsyncThrowingStream<Element, any Error> {
        StreamParsing.ndjson(try await performStreaming(endpoint, isolation: isolation).chunks, as: Element.self, decoder: decoder)
    }

    /// `kind: .sse` → eventos de servidor.
    public func performServerEvents(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> AsyncThrowingStream<ServerEvent, any Error> {
        var endpoint = endpoint
        endpoint.headers["Accept"] = endpoint.headers["Accept"] ?? "text/event-stream"
        return StreamParsing.serverEvents(try await performStreaming(endpoint, isolation: isolation).chunks)
    }

    // MARK: - Ejecución (una variante por familia de retorno; la macro elige)

    /// Envía la petición ya formada: interceptores del usuario → opciones (caché, single-flight,
    /// reintentos, timeout) → transporte. No valida el status.
    public func send(_ request: Request) async throws -> Response {
        let engine = self.engine
        let transport = self.transport
        return try await InterceptorChain.run(interceptors, request: request, transport: ClosureTransport { request in
            try await engine.send(request, options: request.options) { try await transport.send($0) }
        })
    }

    /// Envía y valida 2xx. Base de las demás variantes.
    public func performResponse(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> Response {
        let request = try makeRequest(endpoint)
        let response = try await send(request)
        guard response.isSuccess else { throw HTTPError.status(response.status, response) }
        return response
    }

    /// Retorno `Decodable`. Con `unwrapping`, decodifica solo el sub-árbol de esa ruta de claves (`"data"`, `"data.user"`).
    public func perform<Out: Decodable>(_ endpoint: Endpoint, unwrapping keyPath: String? = nil, isolation: isolated (any Actor)? = #isolation) async throws -> Out {
        let response = try await performResponse(endpoint, isolation: isolation)
        return try decode(Out.self, from: response, unwrapping: keyPath)
    }

    /// Decodifica el body de una respuesta como lo haría ``perform(_:unwrapping:isolation:)``.
    public func decode<Out: Decodable>(_ type: Out.Type, from response: Response, unwrapping keyPath: String? = nil) throws -> Out {
        do {
            let data = try keyPath.map { try Envelope.unwrap(response.body, keyPath: $0) } ?? response.body
            return try decoder.decode(Out.self, from: data)
        } catch {
            throw HTTPError.decoding(error, response)
        }
    }

    /// Intenta convertir un ``HTTPError/status(_:_:)`` en un error de dominio con un ``Transformer``
    /// cuyo `Output` es `Error`. Si el body no decodifica como `Input`, devuelve el error original.
    public func mapError<Mapper: Transformer>(_ error: any Error, with mapper: Mapper.Type, unwrapping keyPath: String? = nil) -> any Error where Mapper.Output: Error {
        guard case HTTPError.status(_, let response) = error,
              let input = try? decode(Mapper.Input.self, from: response, unwrapping: keyPath),
              let mapped = try? Mapper().transform(input) else { return error }
        return mapped
    }

    /// Retorno `Void`.
    public func performVoid(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws {
        _ = try await performResponse(endpoint, isolation: isolation)
    }

    /// Retorno `Data`.
    public func performData(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> Data {
        try await performResponse(endpoint, isolation: isolation).body
    }

    /// Retorno `String` (UTF-8).
    public func performString(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> String {
        let response = try await performResponse(endpoint, isolation: isolation)
        guard let text = response.text else {
            throw HTTPError.decoding(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "body is not UTF-8")), response)
        }
        return text
    }
}

// MARK: - Codificación de bodies

struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

/// Campos sueltos → objeto JSON `{ "user": …, "password": … }`.
struct FieldsBody: Encodable {
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    let fields: [(String, any Encodable)]
    init(_ fields: [(String, any Encodable)]) { self.fields = fields }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (name, value) in fields {
            try container.encode(AnyEncodable(value), forKey: Key(name))
        }
    }
}


/// Transporte definido por un closure; permite insertar el motor de opciones al final de la cadena.
struct ClosureTransport: HTTPClient {
    let body: @Sendable (Request) async throws -> Response
    init(_ body: @escaping @Sendable (Request) async throws -> Response) { self.body = body }
    func send(_ request: Request) async throws -> Response { try await body(request) }
}
