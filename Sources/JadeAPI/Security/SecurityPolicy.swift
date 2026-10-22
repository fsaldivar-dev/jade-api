import Foundation

/// Defaults seguros del cliente. Se aplican en todos los niveles; en el nivel 1 son lo único que
/// el usuario nota de "seguridad", y no tiene que configurar nada.
public struct SecurityPolicy: Sendable, Equatable {
    /// `http://` solo se permite en builds de depuración. En release, una URL insegura falla antes de salir.
    public var allowsInsecureHTTP: Bool
    /// Nombres de header y de parámetro cuyo valor nunca se escribe en logs.
    public var sensitiveKeys: Set<String>

    public init(allowsInsecureHTTP: Bool = SecurityPolicy.isDebugBuild, sensitiveKeys: Set<String> = SecurityPolicy.defaultSensitiveKeys) {
        self.allowsInsecureHTTP = allowsInsecureHTTP
        self.sensitiveKeys = sensitiveKeys
    }

    public static let `default` = SecurityPolicy()

    /// `true` cuando la librería se compila en configuración Debug (la misma que la app).
    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static let defaultSensitiveKeys: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
        "x-api-key", "api-key", "apikey", "api_key", "x-auth-token", "x-access-token",
        "token", "access_token", "refresh_token", "id_token", "password", "passwd", "secret", "client_secret",
        "pan", "card_number", "cardnumber", "cvv", "cvc", "pin", "otp", "ssn", "curp", "rfc",
    ]

    public func isSensitive(_ key: String) -> Bool {
        sensitiveKeys.contains(key.lowercased())
    }

    /// Comprueba el esquema. Lanza ``HTTPError/insecureURL(_:)`` si es `http` y no está permitido.
    public func validate(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else { throw HTTPError.invalidURL(url.absoluteString) }
        if scheme == "https" { return }
        if scheme == "http", allowsInsecureHTTP { return }
        throw HTTPError.insecureURL(url)
    }

    /// Redacta el valor si la clave es sensible.
    public func redacted(_ key: String, _ value: String) -> String {
        isSensitive(key) ? "•••" : value
    }

    /// Redacta las claves sensibles de una query y de un JSON plano (primer nivel) para logs.
    public func redactedQuery(of url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.queryItems = components.queryItems?.map { item in
            URLQueryItem(name: item.name, value: item.value.map { redacted(item.name, $0) })
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    public func redactedBody(_ body: Data?) -> String? {
        guard let body else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let cleaned = object.mapValues { $0 }.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = isSensitive(pair.key) ? "•••" : pair.value
            }
            if let data = try? JSONSerialization.data(withJSONObject: cleaned, options: [.sortedKeys]) {
                return String(data: data, encoding: .utf8)
            }
        }
        return String(data: body, encoding: .utf8)
    }
}

/// Avisos de desarrollo: solo en Debug, una vez por mensaje, nunca lanzan.
public enum SecurityAudit {
    nonisolated(unsafe) private static var reported: Set<String> = []
    private static let lock = NSLock()

    /// Advierte cuando un header con nombre de credencial se fija con un valor literal en el cliente.
    public static func checkStaticHeaders(_ headers: [String: String], origin: String) {
        #if DEBUG
        for (name, value) in headers where SecurityPolicy.default.isSensitive(name) && !value.isEmpty {
            warn("'\(name)' se fija con un valor fijo en \(origin). Un secreto en el cliente es público: usa un TokenProvider, un interceptor o un backend intermedio.")
        }
        #endif
    }

    static func warn(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        guard reported.insert(message).inserted else { return }
        print("⚠️ JadeAPI: \(message)")
    }
}
