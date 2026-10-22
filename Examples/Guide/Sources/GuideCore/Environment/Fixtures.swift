import Foundation
import JadeAPI
import JadeTesting

/// Lo que el servidor "respondería" en el entorno `mock`, con las mismas formas que las APIs reales.
/// Cambiar aquí cambia la demo sin tocar vistas ni repositorios. Cada llamada crea un servidor nuevo,
/// así las pruebas no comparten estado.
public enum Fixtures {

    /// Usuarios aceptados en mock. Los mismos que acepta dummyjson.com en `live`.
    public static let users = ["emilys": "emilyspass", "michaelw": "michaelwpass"]

    public static func makeClient(latency: Duration = .milliseconds(300)) -> MockClient {
        let mock = MockClient()
        mock.latency = latency
        registerAuth(on: mock)
        registerCatalog(on: mock)
        registerWiki(on: mock)
        registerPhotos(on: mock)
        return mock
    }

    // MARK: auth (dummyjson.com)

    private static func registerAuth(on mock: MockClient) {
        mock.on(.post, "/auth/login") { request in
            struct Credentials: Decodable { let username: String; let password: String }
            guard let body = request.body, let credentials = try? JSONDecoder().decode(Credentials.self, from: body),
                  users[credentials.username] == credentials.password else {
                return .json(#"{"message": "Invalid credentials"}"#, status: 400)
            }
            return .json(#"{"accessToken": "tok-\#(credentials.username)", "refreshToken": "ref-\#(credentials.username)"}"#)
        }
        mock.on(.get, "/auth/me") { request in
            guard let auth = request.headers["Authorization"], auth.hasPrefix("Bearer tok-") else {
                return .json(#"{"message": "Token Missing"}"#, status: 401)
            }
            let user = auth.replacingOccurrences(of: "Bearer tok-", with: "")
            return .json(#"{"id": 1, "username": "\#(user)", "firstName": "\#(user.capitalized)", "lastName": "Mock", "image": "https://dummyjson.com/icon/\#(user)/128"}"#)
        }
    }

    // MARK: catalog (dummyjson.com)

    private static func registerCatalog(on mock: MockClient) {
        // La primera carga de destacados falla con 503 para ver `@Retries` en acción.
        let featuredCalls = CallCounter()
        mock.on(.get, "/products") { _ in
            if featuredCalls.next() == 1 { return .status(503) }
            let products = [
                #"{"id": 1, "title": "Essence Mascara", "price": 9.99, "thumbnail": "https://cdn.dummyjson.com/product-images/beauty/essence-mascara-lash-princess/thumbnail.webp"}"#,
                #"{"id": 2, "title": "Eyeshadow Palette", "price": 19.99, "thumbnail": "https://cdn.dummyjson.com/product-images/beauty/eyeshadow-palette-with-mirror/thumbnail.webp"}"#,
                #"{"id": 3, "title": "Powder Canister", "price": 14.99, "thumbnail": "https://cdn.dummyjson.com/product-images/beauty/powder-canister/thumbnail.webp"}"#,
            ]
            return .json(#"{"products": [\#(products.joined(separator: ", "))], "total": 3}"#)
        }
        mock.on(.get, "/products/category-list") { _ in .json(#"["beauty", "fragrances", "furniture"]"#) }
        mock.on(.get, "/products/search") { request in
            let q = (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "q" }?.value ?? "").lowercased()
            let all = [("Essence Mascara", 9.99), ("Eyeshadow Palette", 19.99), ("Powder Canister", 14.99)]
            let hits = all.filter { $0.0.lowercased().contains(q) }
                .enumerated()
                .map { #"{"id": \#($0.offset + 1), "title": "\#($0.element.0)", "price": \#($0.element.1), "thumbnail": "https://cdn.dummyjson.com/x.webp"}"# }
            return .json(#"{"products": [\#(hits.joined(separator: ", "))], "total": \#(hits.count)}"#)
        }
        mock.on(.get, "/products/:id") { request in
            guard let last = request.path.split(separator: "/").last, let id = Int(last) else { return .status(400) }
            guard id != 9999 else { return .json(#"{"message": "Product with id '9999' not found"}"#, status: 404) }
            return .json(#"{"id": \#(id), "title": "Producto \#(id)", "price": \#(id).5, "thumbnail": "https://cdn.dummyjson.com/x.webp"}"#)
        }
    }

    // MARK: wiki (stream.wikimedia.org): cuatro ediciones SSE, una cada 150 ms

    private static func registerWiki(on mock: MockClient) {
        mock.onStream(.get, "/v2/stream/recentchange") { _ in
            let edits = [
                (1, "Jade", "Paco", "eswiki", "edit"),
                (2, "Obsidiana", "Ana", "eswiki", "edit"),
                (3, "Swift (lenguaje)", "Bot-X", "enwiki", "categorize"),
                (4, "Macro", "Luis", "eswiki", "new"),
            ]
            let events = edits.map { id, title, user, wiki, type in
                "event: message\ndata: {\"id\": \(id), \"title\": \"\(title)\", \"user\": \"\(user)\", \"wiki\": \"\(wiki)\", \"type\": \"\(type)\"}\n\n"
            }
            return .text(events, interval: .milliseconds(150))
        }
    }

    // MARK: photos (picsum.photos): bytes de distinto tamaño por semilla

    private static func registerPhotos(on mock: MockClient) {
        mock.on(.get, "/seed/:seed/800/500") { request in
            let seed = request.path.split(separator: "/").dropFirst().first.map(String.init) ?? "1"
            let size = 20_000 + (Int(seed.filter(\.isNumber)) ?? 1) * 10_000
            return MockResponse(headers: ["Content-Type": "application/octet-stream"], body: Data(repeating: 0xAB, count: size))
        }
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
}
