import Foundation
import JadeAPI

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
        return mock
    }()
}
