import Foundation
import JadeAPI
import JadeTesting

/// Entornos de la app. `mock` responde con fixtures sin tocar la red.
enum Stage: String, StageProtocol, CaseIterable, Identifiable {
    case dev, prod, mock

    var id: String { rawValue }

    var baseURL: URL {
        switch self {
        case .dev: URL(string: "https://dev.api.ejemplo.com/v1")!
        case .prod: URL(string: "https://api.ejemplo.com/v1")!
        case .mock: URL(string: "https://mock.local")!
        }
    }

    var transport: any HTTPClient {
        switch self {
        case .mock: Fixtures.client
        case .dev, .prod: URLSessionClient()
        }
    }
}

/// Lo que el servidor "respondería". Cambiar aquí cambia la demo sin tocar vistas ni repositorios.
enum Fixtures {
    static let client: MockClient = {
        let mock = MockClient()
        mock.latency = .milliseconds(400)
        mock.on(.post, "/auth") { request in
            struct Credentials: Decodable { let user: String; let password: String }
            let credentials = try JSONDecoder().decode(Credentials.self, from: request.body ?? Data())
            guard credentials.password == credentials.user else { return .status(401, body: "credenciales inválidas") }
            return .json(#"{"value": "tok-\#(credentials.user)", "expiresIn": 900}"#)
        }
        mock.on(.get, "/me") { request in
            guard let token = request.headers["token"], token.hasPrefix("tok-") else { return .status(401) }
            let user = token.dropFirst(4)
            return .json(#"{"id": 1, "name": "\#(user.capitalized)", "role": "\#(user == "admin" ? "admin" : "viewer")"}"#)
        }
        mock.on(.post, "/auth/logout") { _ in .noContent }

        // Catálogo: exige token; la primera carga de destacados falla con 503 para ver @Retries en acción.
        let featuredCalls = FeaturedCounter()
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
            let id = request.path.split(separator: "/").last.map(String.init) ?? "0"
            guard id != "99" else { return .json(#"{"data": {"code": "NOT_FOUND", "message": "el producto 99 no existe"}}"#, status: 404) }
            return .json(#"{"data": {"id": \#(id), "title": "Producto \#(id)", "price_cents": \#(Int(id)! * 100)}}"#)
        }
        return mock
    }()
}

final class FeaturedCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
