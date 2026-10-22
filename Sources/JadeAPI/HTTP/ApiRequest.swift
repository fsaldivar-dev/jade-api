import Foundation

/// Lo que un objeto de petición (`@ApiRequest`) aporta a un ``Endpoint``: valores de ruta, query,
/// headers y body. La macro `@ApiRequest` genera el método que lo construye; tú no lo creas a mano.
///
/// No es `Sendable` porque el body transporta un `any Encodable`, igual que ``Endpoint``.
public struct ApiRequestInputs {
    public var pathValues: [String: String]
    public var query: [(String, String?)]
    public var headers: [String: String]
    public var body: Endpoint.BodyContent?

    public init(pathValues: [String: String] = [:], query: [(String, String?)] = [], headers: [String: String] = [:], body: Endpoint.BodyContent? = nil) {
        self.pathValues = pathValues
        self.query = query
        self.headers = headers
        self.body = body
    }
}

/// Un objeto de petición: un `struct` con `@ApiRequest` cuyos campos se despliegan en la petición.
/// `@Repository` lo detecta como el único parámetro de un endpoint y lo usa en vez de parámetros sueltos.
///
/// Cada campo decide a dónde va por su tipo: `Path<T>`, `Query<T>`, `Header<T>` y `Body<T>` son
/// explícitos (como en las firmas); un campo pelón, o con `@Parameter`, infiere por el verbo (query en
/// GET/DELETE, campo del body en POST/PUT/PATCH).
public protocol ApiRequest {
    /// El aporte de este objeto a la petición, resuelto con el verbo del endpoint.
    func _inputs(method: HTTPMethod) -> ApiRequestInputs
}
