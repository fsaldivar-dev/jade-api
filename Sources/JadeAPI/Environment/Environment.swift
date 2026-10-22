import Foundation

/// Configuración de un servicio dentro de un entorno: a dónde apunta y con qué política.
public struct ServiceConfiguration: Sendable {
    public var baseURL: URL
    /// Headers propios del servicio; se suman a los del entorno y pierden ante los del endpoint.
    public var headers: [String: String]
    /// Opciones por defecto del servicio; el repositorio y el endpoint ganan campo a campo.
    public var options: RequestOptions
    /// Interceptores del servicio, por dentro de los del entorno (p. ej. su propia autenticación).
    public var interceptors: [any Interceptor]
    /// Transporte propio (mock de un solo servicio, sesión con pinning). `nil` usa el del entorno.
    public var transport: (any HTTPClient)?

    public init(baseURL: URL, headers: [String: String] = [:], options: RequestOptions = .none, interceptors: [any Interceptor] = [], transport: (any HTTPClient)? = nil) {
        self.baseURL = baseURL
        self.headers = headers
        self.options = options
        self.interceptors = interceptors
        self.transport = transport
    }

    public init(baseURL: String, headers: [String: String] = [:], options: RequestOptions = .none, interceptors: [any Interceptor] = [], transport: (any HTTPClient)? = nil) throws {
        guard let url = URL(string: baseURL), url.scheme != nil, url.host != nil else { throw EnvironmentError.invalidURL(service: "?", value: baseURL) }
        self.init(baseURL: url, headers: headers, options: options, interceptors: interceptors, transport: transport)
    }
}

public enum EnvironmentError: Error, Equatable, CustomStringConvertible {
    /// No hay diccionario `JadeAPI` (o la clave indicada) en el Info.plist.
    case missingConfiguration(key: String)
    /// El repositorio pide un servicio que el entorno no define.
    case missingService(String)
    case invalidURL(service: String, value: String)
    /// `http://` fuera de Debug.
    case insecureURL(service: String, url: String)
    /// Un header configurado tiene nombre de credencial: los secretos no van en la configuración.
    case secretInConfiguration(service: String, key: String)

    public var description: String {
        switch self {
        case .missingConfiguration(let key): "no hay configuración '\(key)' en el Info.plist"
        case .missingService(let name): "el entorno no define el servicio '\(name)'"
        case .invalidURL(let service, let value): "URL inválida para '\(service)': \(value)"
        case .insecureURL(let service, let url): "URL insegura para '\(service)' fuera de Debug: \(url)"
        case .secretInConfiguration(let service, let key): "'\(key)' en la configuración de '\(service)' parece una credencial; los secretos no viven en el cliente"
        }
    }
}

/// Nivel 2: varios servicios, un entorno. Resuelve `(servicio) → AppClient` componiendo las capas
/// entorno → servicio → repositorio → endpoint. Se construye en código o desde el `Info.plist`
/// (``init(bundle:key:security:)``), donde Xcode deja los valores de los `.xcconfig` de cada configuración.
public struct Environment: Sendable {

    /// Servicio que usan los repositorios sin `service:`.
    public static let defaultService = "default"

    public var name: String
    public private(set) var services: [String: ServiceConfiguration]
    /// Interceptores para todos los servicios (trazas, headers de app). Los más externos.
    public var interceptors: [any Interceptor]
    public var transport: any HTTPClient
    public var decoder: JSONDecoder
    public var encoder: JSONEncoder
    public var headers: [String: String]
    public var timeout: TimeInterval
    public var security: SecurityPolicy

    public init(
        name: String = "default",
        services: [String: ServiceConfiguration],
        interceptors: [any Interceptor] = [],
        transport: any HTTPClient = URLSessionClient(),
        decoder: JSONDecoder = JSONDecoder(),
        encoder: JSONEncoder = JSONEncoder(),
        headers: [String: String] = ["Accept": "application/json"],
        timeout: TimeInterval = 30,
        security: SecurityPolicy = .default
    ) {
        self.name = name
        self.services = services
        self.interceptors = interceptors
        self.transport = transport
        self.decoder = decoder
        self.encoder = encoder
        self.headers = headers
        self.timeout = timeout
        self.security = security
    }

    /// Nivel 1 dentro del nivel 2: un solo servicio por defecto.
    public init(baseURL: URL, interceptors: [any Interceptor] = [], transport: any HTTPClient = URLSessionClient()) {
        self.init(services: [Self.defaultService: ServiceConfiguration(baseURL: baseURL)], interceptors: interceptors, transport: transport)
    }

    // MARK: - Resolución

    /// Cliente de un servicio: base y headers del servicio, interceptores del entorno y luego del
    /// servicio, opciones del servicio como base, transporte del servicio o del entorno.
    public func client(for service: String = Environment.defaultService) throws -> AppClient {
        guard let configuration = services[service] else { throw EnvironmentError.missingService(service) }
        var client = AppClient(
            baseURL: configuration.baseURL,
            transport: configuration.transport ?? transport,
            interceptors: interceptors + configuration.interceptors,
            decoder: decoder,
            encoder: encoder,
            headers: headers.merging(configuration.headers) { _, service in service },
            timeout: timeout
        )
        client.options = configuration.options
        client.security = security
        return client
    }

    public func configuration(for service: String) -> ServiceConfiguration? { services[service] }

    /// Copia con un servicio redirigido a otro transporte (mock de un solo servicio en pruebas,
    /// sesión con pinning en producción).
    public func overriding(service: String, transport: any HTTPClient) -> Environment {
        var copy = self
        copy.services[service]?.transport = transport
        return copy
    }

    /// Copia con un servicio añadido o reemplazado.
    public func overriding(service: String, with configuration: ServiceConfiguration) -> Environment {
        var copy = self
        copy.services[service] = configuration
        return copy
    }

    /// Comprueba todo el entorno de golpe (arranque de la app): URLs y headers de cada servicio.
    public func validate() throws {
        for (name, configuration) in services {
            do { try security.validate(configuration.baseURL) }
            catch { throw EnvironmentError.insecureURL(service: name, url: configuration.baseURL.absoluteString) }
            for key in configuration.headers.keys where security.isSensitive(key) {
                throw EnvironmentError.secretInConfiguration(service: name, key: key)
            }
        }
        for key in headers.keys where security.isSensitive(key) {
            throw EnvironmentError.secretInConfiguration(service: "*", key: key)
        }
    }

    // MARK: - Overrides de desarrollo (no existen en release)

    #if DEBUG
    /// Redirige servicios desde argumentos de lanzamiento (`--service.payments=http://localhost:8080`)
    /// y variables de entorno (`JADE_SERVICE_PAYMENTS=…`). Solo compila en Debug: en release esta
    /// función no existe, así que ninguna configuración externa puede mover el tráfico.
    public func applyingLaunchOverrides(
        arguments: [String] = CommandLine.arguments,
        environment variables: [String: String] = ProcessInfo.processInfo.environment
    ) -> Environment {
        var copy = self
        for argument in arguments where argument.hasPrefix("--service.") {
            let body = argument.dropFirst("--service.".count)
            guard let equals = body.firstIndex(of: "=") else { continue }
            let service = String(body[..<equals])
            let value = String(body[body.index(after: equals)...])
            if let url = URL(string: value) { copy.services[service]?.baseURL = url }
        }
        for (key, value) in variables where key.hasPrefix("JADE_SERVICE_") {
            let service = key.dropFirst("JADE_SERVICE_".count).lowercased()
            if let url = URL(string: value) { copy.services[service]?.baseURL = url }
        }
        return copy
    }
    #endif
}
