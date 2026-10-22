import Foundation

extension Environment {

    /// Lee el entorno del `Info.plist`, donde Xcode deja los valores de los `.xcconfig` de la
    /// configuración activa. Es la forma estándar de separar entornos en una app iOS: lo que no
    /// está en `Release.xcconfig` no existe en el binario de tienda.
    ///
    /// Formato esperado bajo la clave `JadeAPI` (sustituciones `$(…)` resueltas por Xcode):
    ///
    /// ```xml
    /// <key>JadeAPI</key>
    /// <dict>
    ///     <key>stage</key>   <string>$(JADE_STAGE)</string>
    ///     <key>baseURL</key> <string>$(JADE_BASE_URL)</string>          <!-- nivel 1: un solo servicio -->
    ///     <key>services</key>                                          <!-- nivel 2 -->
    ///     <dict>
    ///         <key>users</key>    <dict><key>baseURL</key><string>$(JADE_USERS_BASE_URL)</string></dict>
    ///         <key>payments</key> <dict><key>baseURL</key><string>$(JADE_PAYMENTS_BASE_URL)</string>
    ///                                   <key>timeout</key><string>10</string>
    ///                                   <key>retries</key><string>0</string></dict>
    ///     </dict>
    /// </dict>
    /// ```
    ///
    /// Claves por servicio: `baseURL` (obligatoria), `headers` (diccionario), `timeout` y `cache`
    /// (segundos), `retries` (intentos), `pins` (string con pins `sha256/…` separados por espacios) y
    /// `pinsExpire` (fecha ISO 8601 tras la cual el pinning deja de aplicarse). Un header con nombre
    /// de credencial falla: los secretos no viven en la configuración.
    public init(bundle: Bundle = .main, key: String = "JadeAPI", security: SecurityPolicy = .default) throws {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? [String: Any] else {
            throw EnvironmentError.missingConfiguration(key: key)
        }
        try self.init(plist: raw, security: security)
    }

    /// Misma lectura que ``init(bundle:key:security:)`` a partir de un diccionario ya cargado.
    public init(plist raw: [String: Any], security: SecurityPolicy = .default) throws {
        var services: [String: ServiceConfiguration] = [:]
        if let base = raw["baseURL"] as? String {
            services[Environment.defaultService] = try Self.service(named: Environment.defaultService, from: ["baseURL": base])
        }
        if let list = raw["services"] as? [String: Any] {
            for (name, value) in list {
                guard let fields = value as? [String: Any] else { throw EnvironmentError.invalidURL(service: name, value: "\(value)") }
                services[name] = try Self.service(named: name, from: fields)
            }
        }
        let headers = (raw["headers"] as? [String: String]) ?? ["Accept": "application/json"]
        let timeout = Self.seconds(raw["timeout"]) ?? 30
        self.init(name: (raw["stage"] as? String) ?? "default", services: services, headers: headers, timeout: timeout, security: security)
        try validate()
    }

    private static func service(named name: String, from fields: [String: Any]) throws -> ServiceConfiguration {
        guard let text = fields["baseURL"] as? String, let url = URL(string: text), url.scheme != nil, url.host != nil else {
            throw EnvironmentError.invalidURL(service: name, value: "\(fields["baseURL"] ?? "")")
        }
        var options = RequestOptions()
        if let seconds = seconds(fields["timeout"]) { options.timeout = .seconds(seconds) }
        if let seconds = seconds(fields["cache"]) { options.cache = .seconds(seconds) }
        if let attempts = fields["retries"].flatMap(integer) { options.retry = RetryPolicy(attempts: attempts) }
        var pins: PinningPolicy.HostPins?
        if let text = fields["pins"] as? String {
            let list = text.split(whereSeparator: { $0 == " " || $0 == "," }).map { PublicKeyPin(String($0)) }
            if !list.isEmpty {
                let expires = (fields["pinsExpire"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                pins = PinningPolicy.HostPins(list, expires: expires)
            }
        }
        return ServiceConfiguration(baseURL: url, headers: (fields["headers"] as? [String: String]) ?? [:], options: options, pins: pins)
    }

    private static func seconds(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: number.doubleValue
        case let text as String: Double(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    private static func integer(_ value: Any) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }
}
