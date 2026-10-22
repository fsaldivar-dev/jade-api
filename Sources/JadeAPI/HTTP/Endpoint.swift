import Foundation

/// Descripción de una llamada antes de convertirse en `Request`. La genera `@Repository`
/// a partir de la firma del requisito y de `@Api`; el usuario no la construye a mano.
///
/// No es `Sendable` porque transporta los valores reales de los parámetros; por eso
/// ``AppClient/perform(_:isolation:)-swift.method`` corre en el aislamiento de quien llama.
public struct Endpoint {

    /// Contenido del body antes de codificarse.
    public enum BodyContent {
        /// Un único valor `Encodable`, de un parámetro `Body<T>`.
        case value(any Encodable)
        /// Campos sueltos (`user`, `password`) que se codifican como un objeto JSON.
        case fields([(String, any Encodable)])
    }

    /// Nombre del requisito con etiquetas: `"auth(user:password:)"`. Identifica la petición en logs y mocks.
    public var name: String
    public var method: HTTPMethod
    /// Plantilla de ruta con parámetros `:nombre`.
    public var path: String
    public var pathParameters: [String: String]
    public var query: [(String, String?)]
    public var headers: [String: String]
    public var body: BodyContent?

    public init(
        name: String,
        method: HTTPMethod,
        path: String,
        pathParameters: [String: String] = [:],
        query: [(String, String?)] = [],
        headers: [String: String] = [:],
        body: BodyContent? = nil
    ) {
        self.name = name
        self.method = method
        self.path = path
        self.pathParameters = pathParameters
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Ruta con los `:parámetros` sustituidos y percent-encoded.
    public func resolvedPath() throws -> String {
        var resolved = path
        for (name, value) in pathParameters {
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) else {
                throw HTTPError.invalidURL("cannot encode path parameter '\(name)'")
            }
            resolved = resolved.replacingOccurrences(of: ":\(name)", with: encoded)
        }
        if let missing = resolved.split(separator: "/").first(where: { $0.hasPrefix(":") }) {
            throw HTTPError.invalidURL("missing value for path parameter '\(missing)' in '\(path)'")
        }
        return resolved
    }
}

/// Convierte cualquier valor a texto para query, path y headers. `nil` se omite.
public enum ParameterValue {
    public static func text(_ value: Any) -> String? {
        if case Optional<Any>.none = value { return nil }
        if let optional = value as? OptionalProtocol { return optional.unwrappedText }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return String(describing: value)
    }
}

private protocol OptionalProtocol { var unwrappedText: String? { get } }
extension Optional: OptionalProtocol {
    fileprivate var unwrappedText: String? {
        switch self {
        case .none: nil
        case .some(let wrapped): ParameterValue.text(wrapped)
        }
    }
}
