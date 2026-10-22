import Foundation

/// Producto del catálogo en términos de la app: `name` en vez de `title`, precio como `Decimal`.
public struct Product: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let price: Decimal
    public let thumbnail: URL?
}

/// Error de negocio que el servidor del catálogo devuelve en el body de un 4xx: `{"message": "..."}`.
public enum CatalogError: Error, Equatable, CustomStringConvertible {
    case server(message: String)

    public var description: String {
        switch self {
        case .server(let message): message
        }
    }
}
