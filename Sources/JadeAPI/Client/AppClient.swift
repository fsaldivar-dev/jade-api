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

        return Request(method: endpoint.method, url: url, path: path, headers: headers, body: body, timeout: timeout, endpoint: endpoint.name)
    }

    // MARK: - Ejecución (una variante por familia de retorno; la macro elige)

    /// Envía la petición ya formada a través de la cadena de interceptores y el transporte, sin validar el status.
    public func send(_ request: Request) async throws -> Response {
        try await InterceptorChain.run(interceptors, request: request, transport: transport)
    }

    /// Envía y valida 2xx. Base de las demás variantes.
    public func performResponse(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> Response {
        let request = try makeRequest(endpoint)
        let response = try await send(request)
        guard response.isSuccess else { throw HTTPError.status(response.status, response) }
        return response
    }

    /// Retorno `Decodable`.
    public func perform<Out: Decodable>(_ endpoint: Endpoint, isolation: isolated (any Actor)? = #isolation) async throws -> Out {
        let response = try await performResponse(endpoint, isolation: isolation)
        do {
            return try decoder.decode(Out.self, from: response.body)
        } catch {
            throw HTTPError.decoding(error, response)
        }
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
