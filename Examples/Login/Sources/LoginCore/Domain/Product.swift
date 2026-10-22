import Foundation

/// Producto del catálogo, ya en términos de dominio (nombre y precio en pesos, no centavos).
public struct Product: Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let price: Decimal

    public init(id: Int, name: String, price: Decimal) {
        self.id = id
        self.name = name
        self.price = price
    }
}

/// Error de negocio que el servidor del catálogo devuelve en el body de un 4xx.
public enum CatalogError: Error, Equatable, CustomStringConvertible {
    case api(code: String, message: String)

    public var description: String {
        switch self {
        case .api(let code, let message): "\(code): \(message)"
        }
    }
}
