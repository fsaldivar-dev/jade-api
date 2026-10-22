import Foundation

/// Convierte lo que decodifica la red (`Input`, un DTO) en lo que devuelve el endpoint (`Output`).
///
/// ```swift
/// struct UserMapper: Transformer {
///     func transform(_ dto: UserDTO) throws -> User { User(id: dto.id, name: dto.full_name) }
/// }
///
/// @Repository
/// protocol UsersRepository: Sendable {
///     @Transform(UserMapper.self)
///     @Api("/users/:id")
///     func user(id: Int) async throws -> User     // la red devuelve UserDTO; tú recibes User
/// }
/// ```
///
/// Es un tipo y no un closure para que el compilador verifique que `Input` es lo que se decodifica
/// y `Output` coincide con el retorno del requisito.
public protocol Transformer {
    associatedtype Input: Decodable
    associatedtype Output
    init()
    func transform(_ input: Input) throws -> Output
}

/// Extrae un sub-árbol del JSON por ruta de claves (`"data"`, `"data.user"`) antes de decodificar.
/// Lo usa `@Unwrap`.
enum Envelope {
    static func unwrap(_ data: Data, keyPath: String) throws -> Data {
        var node = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        for key in keyPath.split(separator: ".").map(String.init) {
            guard let object = node as? [String: Any], let next = object[key] else {
                throw DecodingError.keyNotFound(EnvelopeKey(key), .init(codingPath: [], debugDescription: "key '\(key)' not found while unwrapping '\(keyPath)'"))
            }
            node = next
        }
        return try JSONSerialization.data(withJSONObject: node, options: [.fragmentsAllowed])
    }

    struct EnvelopeKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}
