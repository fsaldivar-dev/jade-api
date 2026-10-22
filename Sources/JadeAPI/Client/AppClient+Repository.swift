import Foundation

/// Cómo se traducen las claves JSON a propiedades Swift. Se declara con `@KeyMapping` sobre un
/// repositorio o con ``AppClient/with(keys:dates:)`` sobre un cliente.
public enum KeyMapping: Sendable, Hashable {
    /// `full_name` en el JSON ↔ `fullName` en Swift, en los dos sentidos.
    case snakeCase
    /// Las claves tal cual (los `CodingKeys` del tipo mandan).
    case asIs
}

/// Cómo se leen y escriben las fechas.
public enum DateMapping: Sendable, Hashable {
    case iso8601
    case secondsSince1970
    case millisecondsSince1970
    /// Un formato de `DateFormatter` fijo (`"yyyy-MM-dd"`), interpretado en POSIX y UTC.
    case formatted(String)
}

extension AppClient {

    /// Copia del cliente con headers añadidos para todas sus peticiones. Los del endpoint siguen ganando.
    /// Lo usa `@Headers` a nivel de repositorio.
    public func with(headers extra: [String: String]) -> AppClient {
        var copy = self
        copy.headers.merge(extra) { _, new in new }
        SecurityAudit.checkStaticHeaders(extra, origin: "@Headers")
        return copy
    }

    /// Copia del cliente con otra base. Un valor que empieza por `/` se añade como prefijo de ruta a la
    /// base actual (`"/v2"`); una URL completa la sustituye. Lo usa `@BaseURL` a nivel de repositorio.
    public func with(base: String) -> AppClient {
        var copy = self
        if base.hasPrefix("/") {
            let prefix = base.drop(while: { $0 == "/" })
            copy.baseURL = prefix.isEmpty ? baseURL : baseURL.appendingPathComponent(String(prefix))
        } else {
            guard let url = URL(string: base), url.scheme != nil else {
                preconditionFailure("AppClient.with(base:): '\(base)' no es un prefijo de ruta ni una URL")
            }
            copy.baseURL = url
        }
        return copy
    }

    /// Copia del cliente con otra traducción de claves y, opcionalmente, de fechas. Los codificadores
    /// originales no se tocan: se copian con la nueva estrategia. Lo usa `@KeyMapping` a nivel de repositorio.
    public func with(keys: KeyMapping, dates: DateMapping? = nil) -> AppClient {
        var copy = self
        let decoder = self.decoder.copy()
        let encoder = self.encoder.copy()
        switch keys {
        case .snakeCase:
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            encoder.keyEncodingStrategy = .convertToSnakeCase
        case .asIs:
            decoder.keyDecodingStrategy = .useDefaultKeys
            encoder.keyEncodingStrategy = .useDefaultKeys
        }
        if let dates {
            switch dates {
            case .iso8601:
                decoder.dateDecodingStrategy = .iso8601
                encoder.dateEncodingStrategy = .iso8601
            case .secondsSince1970:
                decoder.dateDecodingStrategy = .secondsSince1970
                encoder.dateEncodingStrategy = .secondsSince1970
            case .millisecondsSince1970:
                decoder.dateDecodingStrategy = .millisecondsSince1970
                encoder.dateEncodingStrategy = .millisecondsSince1970
            case .formatted(let format):
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = format
                decoder.dateDecodingStrategy = .formatted(formatter)
                encoder.dateEncodingStrategy = .formatted(formatter)
            }
        }
        copy.decoder = decoder
        copy.encoder = encoder
        return copy
    }
}

extension JSONDecoder {
    /// Copia con la misma configuración; `JSONDecoder` es una clase y no se debe mutar la del cliente original.
    func copy() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo = userInfo
        decoder.dateDecodingStrategy = dateDecodingStrategy
        decoder.dataDecodingStrategy = dataDecodingStrategy
        decoder.nonConformingFloatDecodingStrategy = nonConformingFloatDecodingStrategy
        decoder.keyDecodingStrategy = keyDecodingStrategy
        decoder.allowsJSON5 = allowsJSON5
        decoder.assumesTopLevelDictionary = assumesTopLevelDictionary
        return decoder
    }
}

extension JSONEncoder {
    func copy() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.userInfo = userInfo
        encoder.outputFormatting = outputFormatting
        encoder.dateEncodingStrategy = dateEncodingStrategy
        encoder.dataEncodingStrategy = dataEncodingStrategy
        encoder.nonConformingFloatEncodingStrategy = nonConformingFloatEncodingStrategy
        encoder.keyEncodingStrategy = keyEncodingStrategy
        return encoder
    }
}
