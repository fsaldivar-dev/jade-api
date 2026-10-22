import Foundation

/// Petición lista para viajar: URL absoluta, headers y body ya codificado. Es lo que recibe
/// un ``HTTPClient`` y lo que ven los mocks.
public struct Request: Sendable, Hashable {
    public var method: HTTPMethod
    public var url: URL
    /// Ruta relativa a la base, ya resuelta, para emparejar mocks y para logs: `"/users/7"`.
    public var path: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval?
    /// Nombre del requisito que originó la petición: `"getUser(id:)"`.
    public var endpoint: String
    /// Opciones declaradas sobre el endpoint; las aplica el cliente, pero un interceptor puede leerlas o cambiarlas.
    public var options: RequestOptions

    public init(method: HTTPMethod, url: URL, path: String, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval? = nil, endpoint: String = "", options: RequestOptions = .none) {
        self.method = method
        self.url = url
        self.path = path
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.endpoint = endpoint
        self.options = options
    }

    /// `URLRequest` equivalente.
    public var urlRequest: URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawHTTP
        request.httpBody = body
        if let timeout { request.timeoutInterval = timeout }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// Descripción `curl` de la petición, útil en logs.
    public var curl: String {
        var parts = ["curl -X \(method.rawHTTP)"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { parts.append("-H '\(name): \(value)'") }
        if let body, let text = String(data: body, encoding: .utf8) { parts.append("-d '\(text)'") }
        parts.append("'\(url.absoluteString)'")
        return parts.joined(separator: " ")
    }
}

/// Respuesta cruda. Es lo que devuelve un ``HTTPClient`` y lo que recibe un endpoint declarado `-> Response`.
public struct Response: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
    public let request: Request
    /// Lo que midió el transporte en el intento que respondió; `nil` si el transporte no mide.
    public var metrics: TransportMetrics?
    /// Intentos que hizo `@Retries` hasta esta respuesta (1 = a la primera).
    public var attempts: Int

    public init(status: Int, headers: [String: String] = [:], body: Data = Data(), request: Request, metrics: TransportMetrics? = nil, attempts: Int = 1) {
        self.status = status
        self.headers = headers
        self.body = body
        self.request = request
        self.metrics = metrics
        self.attempts = attempts
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
    public var text: String? { String(data: body, encoding: .utf8) }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
