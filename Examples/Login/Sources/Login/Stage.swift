import Foundation
import JadeAPI
import JadeTesting

/// Entornos de la app. En una app con proyecto de Xcode esto sale de `Environment(bundle: .main)`,
/// que lee el Info.plist alimentado por los `.xcconfig` de `Config/` (uno por Build Configuration).
/// Este ejemplo es un paquete SwiftPM sin Info.plist, así que construye el mismo `Environment` en código.
enum Stage: String, CaseIterable, Identifiable {
    case dev, prod, mock

    var id: String { rawValue }

    /// Dos servicios: `auth` y `catalog`, cada uno con su base.
    var plist: [String: Any] {
        switch self {
        case .dev: ["stage": "dev", "services": [
            "auth":    ["baseURL": "https://auth.dev.ejemplo.com"],
            "catalog": ["baseURL": "https://catalog.dev.ejemplo.com/v2", "timeout": "10", "retries": "2"]]]
        case .prod: ["stage": "prod", "services": [
            "auth":    ["baseURL": "https://auth.ejemplo.com"],
            "catalog": ["baseURL": "https://catalog.ejemplo.com/v2", "timeout": "10", "retries": "2"]]]
        case .mock: ["stage": "mock", "services": [
            "auth":    ["baseURL": "https://auth.mock.local"],
            "catalog": ["baseURL": "https://catalog.mock.local/v2", "retries": "2"]]]
        }
    }

    /// `Environment` del stage. En `mock`, los dos servicios van al mismo `MockClient` de fixtures.
    func environment(interceptors: [any Interceptor]) throws -> Environment {
        var environment = try Environment(plist: plist)
        environment.interceptors = interceptors
        #if DEBUG
        environment = environment.applyingLaunchOverrides()   // --service.catalog=http://localhost:8080
        #endif
        if self == .mock { environment = environment.mockingAll(with: Fixtures.client) }
        return environment
    }

    /// "auth → https://…  ·  catalog → https://…", para la UI.
    var servicesSummary: String {
        ((plist["services"] as? [String: [String: Any]]) ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key) → \($0.value["baseURL"] ?? "")" }
            .joined(separator: "  ·  ")
    }

    static func resolve(fallback: Stage) -> Stage {
        let argument = CommandLine.arguments.first { $0.hasPrefix("--stage=") }.map { String($0.dropFirst("--stage=".count)) }
        return argument.flatMap(Stage.init(rawValue:)) ?? ProcessInfo.processInfo.environment["JADE_STAGE"].flatMap(Stage.init(rawValue:)) ?? fallback
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
