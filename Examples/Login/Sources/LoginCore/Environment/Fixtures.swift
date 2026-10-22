import Foundation
import JadeAPI
import JadeTesting

/// Lo que el servidor "respondería" en el entorno `mock`. Cambiar aquí cambia la demo sin tocar
/// vistas ni repositorios. Cada llamada crea un servidor nuevo, así las pruebas no comparten estado.
public enum Fixtures {

    /// Usuarios aceptados: la contraseña es el mismo nombre.
    public static let users = ["admin": "admin", "viewer": "viewer"]

    public static func makeClient(latency: Duration = .milliseconds(400)) -> MockClient {
        let mock = MockClient()
        mock.latency = latency
        registerAuth(on: mock)
        registerCatalog(on: mock)
        return mock
    }

    private static func registerAuth(on mock: MockClient) {
        mock.on(.post, "/auth") { request in
            struct Credentials: Decodable { let user: String; let password: String }
            guard let body = request.body, let credentials = try? JSONDecoder().decode(Credentials.self, from: body),
                  users[credentials.user] == credentials.password else {
                return .status(401, body: "credenciales inválidas")
            }
            return .json(#"{"value": "tok-\#(credentials.user)", "expiresIn": 900}"#)
        }
        mock.on(.get, "/me") { request in
            guard let token = request.headers["token"], token.hasPrefix("tok-") else { return .status(401) }
            let user = String(token.dropFirst("tok-".count))
            return .json(#"{"id": 1, "name": "\#(user.capitalized)", "role": "\#(user == "admin" ? "admin" : "viewer")"}"#)
        }
        mock.on(.post, "/auth/logout") { _ in .noContent }
    }

    private static func registerCatalog(on mock: MockClient) {
        // La primera carga de destacados falla con 503 para ver `@Retries` en acción.
        let featuredCalls = CallCounter()
        mock.on(.get, "/catalog/featured") { request in
            guard request.headers["Authorization"]?.hasPrefix("Bearer tok-") == true else { return .status(401) }
            if featuredCalls.next() == 1 { return .status(503) }
            return .json(#"{"data": [{"id": 1, "title": "Tornillo M4", "price_cents": 1250}, {"id": 2, "title": "Tuerca M4", "price_cents": 450}, {"id": 3, "title": "Arandela", "price_cents": 120}]}"#)
        }
        mock.on(.get, "/catalog/categories") { request in
            guard request.headers["Authorization"] != nil else { return .status(401) }
            return .json(#"{"data": ["Fijación", "Herramienta", "Pintura"]}"#)
        }
        mock.on(.get, "/catalog/:id") { request in
            guard let last = request.path.split(separator: "/").last, let id = Int(last) else { return .status(400) }
            guard id != 99 else {
                return .json(#"{"data": {"code": "NOT_FOUND", "message": "el producto 99 no existe"}}"#, status: 404)
            }
            return .json(#"{"data": {"id": \#(id), "title": "Producto \#(id)", "price_cents": \#(id * 100)}}"#)
        }
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
